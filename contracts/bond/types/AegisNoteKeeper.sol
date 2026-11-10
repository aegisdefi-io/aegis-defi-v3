// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../../interfaces/IATH.sol";
import "../../interfaces/IsATH.sol";
import "../../interfaces/IStaking.sol";
import "../../interfaces/IStakingBond.sol";
import "../../interfaces/ITreasury.sol";

/**
 * @title AegisNoteKeeper
 * @notice Linear-vesting bond NoteKeeper. Each note's `payoutGons` (sATH gons —
 *         rebase-immune) vests linearly between `created` and `matured`; the
 *         user can `redeem()` at any time to receive the portion vested since
 *         the last claim. Mint of the payout ATH is performed by
 *         `treasury.deposit()` in the depository's `deposit()`; this keeper
 *         stakes that ATH into sATH and records the user's claim in gons.
 *
 * Storage layout (post-upgrade):
 *   slot N+0  notes
 *   slot N+1  noteTransfers
 *   slot N+2  ATH
 *   slot N+3  sATH
 *   slot N+4  staking
 *   slot N+5  treasury
 *   slot N+6  _claimedGons   (NEW — partial-claim accounting)
 *   slot N+7..45  __gap[39]  (was __gap[40])
 *
 * Backward-compat: pre-upgrade notes have `_claimedGons[user][i] == 0` (default),
 * which correctly represents "nothing claimed yet". Notes that were fully
 * redeemed pre-upgrade still carry `note.redeemed != 0`, which the new logic
 * treats as "closed" — preventing any double-redeem regardless of `_claimedGons`.
 */
abstract contract AegisNoteKeeper is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Note {
        uint256 payoutGons; // gons units (rebase-immune)
        uint48 created;
        uint48 matured;
        uint48 redeemed;    // != 0 once the note is fully claimed (or transferred out)
        uint48 marketID;
    }

    mapping(address => Note[]) public notes;
    mapping(address => mapping(uint256 => address)) private noteTransfers;

    IATH public ATH;
    IsATH public sATH;
    IStaking public staking;
    ITreasury public treasury;

    // Gons already claimed against `notes[user][index]`. A note is fully closed
    // once `_claimedGons[user][i] >= notes[user][i].payoutGons` (or `redeemed != 0`).
    mapping(address => mapping(uint256 => uint256)) internal _claimedGons;

    function __AegisNoteKeeper_init(
        address ath_,
        address sath_,
        address staking_,
        address treasury_
    ) internal onlyInitializing {
        require(ath_ != address(0), "Zero ATH");
        require(sath_ != address(0), "Zero sATH");
        require(staking_ != address(0), "Zero staking");
        require(treasury_ != address(0), "Zero treasury");

        ATH = IATH(ath_);
        sATH = IsATH(sath_);
        staking = IStaking(staking_);
        treasury = ITreasury(treasury_);

        // depo bulk-approves staking to spend its ATH (gas saving on each deposit())
        IERC20Upgradeable(ath_).approve(staking_, type(uint256).max);
    }

    /* ========== ADD ========== */

    function _addNote(
        address user,
        uint256 payoutATH,
        uint48 expiry,
        uint48 marketID
    ) internal returns (uint256 index_) {
        index_ = notes[user].length;

        // ATH was already minted to this contract by the depository's deposit()
        // flow (via treasury.deposit() and an optional treasury.mint() top-up);
        // stake it through the bond-only entry point so sATH lands here without
        // warmup delay.
        IStakingBond(address(staking)).stakeForBond(address(this), payoutATH);

        // store the staked balance in gons so that subsequent rebases compound the user's claim
        uint256 gons = sATH.gonsForBalance(payoutATH);

        notes[user].push(
            Note({
                payoutGons: gons,
                created: uint48(block.timestamp),
                matured: expiry,
                redeemed: 0,
                marketID: marketID
            })
        );
    }

    /* ========== REDEEM ========== */

    /**
     * @notice Claim the linearly-vested-but-not-yet-claimed portion of each
     *         supplied note and receive it as sATH. Notes that have been
     *         fully claimed (or transferred out) are silently skipped.
     */
    function redeem(address user, uint256[] memory indexes) public nonReentrant returns (uint256 payoutATH) {
        uint48 t = uint48(block.timestamp);
        uint256 totalGons;

        for (uint256 i = 0; i < indexes.length; i++) {
            uint256 idx = indexes[i];
            Note storage note = notes[user][idx];
            if (note.redeemed != 0 || note.payoutGons == 0) continue;

            uint256 vested = _vestedGons(note);
            uint256 claimed = _claimedGons[user][idx];
            if (vested <= claimed) continue;

            uint256 claimable = vested - claimed;
            uint256 newClaimed = claimed + claimable;
            _claimedGons[user][idx] = newClaimed;
            totalGons = totalGons + claimable;

            if (newClaimed >= note.payoutGons) {
                note.redeemed = t;
            }
        }

        if (totalGons > 0) {
            payoutATH = sATH.balanceForGons(totalGons);
            // send sATH to the user (still rebases for them after redemption)
            IERC20Upgradeable(address(sATH)).safeTransfer(user, payoutATH);
        }
    }

    function redeemAll(address user) external returns (uint256) {
        return redeem(user, indexesFor(user));
    }

    /* ========== TRANSFER ========== */

    function pushNote(address to, uint256 index_) external {
        require(notes[msg.sender][index_].created != 0, "Note not found");
        noteTransfers[msg.sender][index_] = to;
    }

    function pullNote(address from, uint256 index_) external nonReentrant returns (uint256 newIndex_) {
        require(noteTransfers[from][index_] == msg.sender, "Transfer not found");
        Note memory src = notes[from][index_];
        require(src.redeemed == 0, "Already redeemed");
        require(src.payoutGons != 0, "Empty note");

        uint256 srcClaimed = _claimedGons[from][index_];
        require(srcClaimed < src.payoutGons, "Already fully claimed");

        // Recipient inherits only the un-claimed remainder, with the same
        // (created, matured) schedule. `from` already collected `srcClaimed`
        // gons through earlier redeem() calls and forfeits the remaining.
        newIndex_ = notes[msg.sender].length;
        notes[msg.sender].push(
            Note({
                payoutGons: src.payoutGons - srcClaimed,
                created: src.created,
                matured: src.matured,
                redeemed: 0,
                marketID: src.marketID
            })
        );

        delete notes[from][index_];
        delete _claimedGons[from][index_];
        delete noteTransfers[from][index_];
    }

    /* ========== VIEW ========== */

    function indexesFor(address user) public view returns (uint256[] memory) {
        Note[] memory arr = notes[user];
        uint256 count;
        for (uint256 i = 0; i < arr.length; i++) {
            if (_isOpen(arr[i], _claimedGons[user][i])) count++;
        }
        uint256[] memory result = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < arr.length; i++) {
            if (_isOpen(arr[i], _claimedGons[user][i])) {
                result[j++] = i;
            }
        }
        return result;
    }

    /// @notice Currently-claimable payout in gons for one note. `matured_` is
    /// `true` once the note is fully vested (block.timestamp >= note.matured).
    /// The user can claim partial amounts at any point before that.
    function pendingForGons(address user, uint256 index_) public view returns (uint256 gons_, bool matured_) {
        Note memory note = notes[user][index_];
        if (note.redeemed != 0 || note.payoutGons == 0) {
            return (0, note.matured <= block.timestamp);
        }
        uint256 vested = _vestedGons(note);
        uint256 claimed = _claimedGons[user][index_];
        gons_ = vested > claimed ? vested - claimed : 0;
        matured_ = block.timestamp >= note.matured;
    }

    /// @notice Currently-claimable payout converted to sATH balance at the
    /// current rebase index.
    function pendingFor(address user, uint256 index_) public view returns (uint256 payoutATH_, bool matured_) {
        (uint256 gons_, bool m_) = pendingForGons(user, index_);
        payoutATH_ = sATH.balanceForGons(gons_);
        matured_ = m_;
    }

    /// @notice Gons that have been claimed against this note so far.
    function claimedForGons(address user, uint256 index_) external view returns (uint256) {
        return _claimedGons[user][index_];
    }

    /// @notice Outstanding (un-claimed-yet) portion of a note in gons. Includes
    /// the still-vesting remainder, not just what is claimable today. Useful
    /// for "total user exposure" reporting in admin tooling.
    function outstandingGonsFor(address user, uint256 index_) public view returns (uint256) {
        Note memory n = notes[user][index_];
        if (n.redeemed != 0 || n.payoutGons == 0) return 0;
        uint256 claimed = _claimedGons[user][index_];
        return claimed >= n.payoutGons ? 0 : n.payoutGons - claimed;
    }

    /// @notice `outstandingGonsFor` converted to sATH balance at current index.
    function outstandingFor(address user, uint256 index_) external view returns (uint256) {
        return sATH.balanceForGons(outstandingGonsFor(user, index_));
    }

    function notesCount(address user) external view returns (uint256) {
        return notes[user].length;
    }

    /* ========== INTERNAL ========== */

    function _vestedGons(Note memory n) internal view returns (uint256) {
        if (n.payoutGons == 0) return 0;
        if (block.timestamp >= n.matured) return n.payoutGons;
        if (block.timestamp <= n.created) return 0;
        // (matured > created) is guaranteed by the depository's create() validation
        // (vested-in-past / zero-vesting checks), so the divisor is non-zero here.
        //
        // mulDiv, not `a * b / c`: payoutGons is in sATH gons (~1e61 per wei),
        // so the plain product `payoutGons * elapsed` exceeds 2^256 for any
        // note above ~150 sATH once enough of a 365d term has elapsed. That
        // reverted pendingFor/redeem/redeemAll with panic 0x11 until maturity
        // (Polygon, 2026-10-21). mulDiv keeps the 512-bit intermediate; the
        // result is always <= payoutGons so it fits.
        return MathUpgradeable.mulDiv(n.payoutGons, block.timestamp - n.created, n.matured - n.created);
    }

    function _isOpen(Note memory n, uint256 claimed) internal pure returns (bool) {
        return n.redeemed == 0 && n.payoutGons != 0 && claimed < n.payoutGons;
    }

    uint256[39] private __gap;
}
