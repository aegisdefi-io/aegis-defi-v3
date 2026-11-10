// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "../interfaces/IATH.sol";
import "../interfaces/IsATH.sol";
import "../interfaces/IDistributor.sol";
import "../interfaces/IStaking.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title AegisStakingV4
 * @notice Storage-compatible upgrade of AegisStakingV3.
 *
 *         **Sole behavioural change vs V3**: adds `stakeForBond(to, amount)` —
 *         a warmup-bypassing entry point reserved for the BondDepository.
 *
 *         Background: regular `stake(to, amount, claim_=true)` enters the
 *         shared `warmupInfo[to]` slot when `warmupPeriod > 0`. The bond
 *         depository deposits all bonders' ATH under `to == address(bond)`,
 *         so every new deposit pushes `warmupInfo[bond].expiry` further into
 *         the future and the depository never accumulates spendable sATH —
 *         making bond redemption impossible while the network maintains a
 *         non-zero warmup. `stakeForBond` sidesteps this by sending sATH to
 *         the depository immediately, while regular users continue to be
 *         subject to `warmupPeriod` on `stake()` as before.
 *
 *         Storage layout: byte-identical to V3. `BOND_ROLE` is a constant and
 *         consumes no storage.
 */
contract AegisStakingV4 is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IStaking
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice depository / bond contracts may stake on behalf of users without warmup.
    bytes32 public constant BOND_ROLE = keccak256("BOND_ROLE");

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant GATH_TO_ATH_DECIMALS_SHIFT = 1e9;

    uint256 public constant MAX_REBASE_BPS_LIMIT = 1000;

    struct Epoch {
        uint256 length;
        uint256 number;
        uint256 end;
        uint256 distribute;
    }

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
        bool lock;
    }

    // ============================== Storage (V1, do not reorder) ==============================

    IATH public ATH;
    IsATH public sATH;
    IDistributor public distributor;

    ITreasury public treasury;

    IERC20Upgradeable public gath;

    Epoch public epochState;

    mapping(address => Claim) public warmupInfo;
    uint256 public warmupPeriod;
    uint256 private gonsInWarmup;

    // ============================== Storage (V2 additions, kept for V3/V4) ==============================

    bool public paused;
    uint256 public maxRebaseBps;
    uint256[33] private __gap;

    // ============================== Events ==============================

    event DistributorSet(address distributor);
    event WarmupSet(uint256 warmup);
    event TreasurySet(address treasury);
    event GathSet(address gath);
    event StakedFromGath(address indexed user, uint256 gathAmount, uint256 athEquiv);

    event Paused(bool state);
    event EpochDistributeCleared(uint256 previous);
    event ATHRescued(address indexed to, uint256 amount);
    event MaxRebaseBpsSet(uint256 previous, uint256 current);
    event RebaseCapped(uint256 raw, uint256 capped, uint256 staked);

    event WarmupAutoSettled(address indexed user, uint256 gons, uint256 sathAmount);

    event StakedForBond(address indexed bond, address indexed to, uint256 amount);

    // ============================== Modifiers ==============================

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address ath_,
        address sath_,
        uint256 epochLength_,
        uint256 firstEpochNumber_,
        uint256 firstEpochTime_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        require(admin_ != address(0), "Zero admin");
        require(ath_ != address(0), "Zero ATH");
        require(sath_ != address(0), "Zero sATH");

        ATH = IATH(ath_);
        sATH = IsATH(sath_);

        epochState = Epoch({
            length: epochLength_,
            number: firstEpochNumber_,
            end: firstEpochTime_,
            distribute: 0
        });

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(BOND_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /**
     * @notice One-shot post-upgrade hook. Sets BOND_ROLE's admin to ADMIN_ROLE
     *         when the V3 proxy is upgraded to V4 (since `initialize` is not
     *         re-run on upgrade). Without this, BOND_ROLE keeps the default
     *         admin (DEFAULT_ADMIN_ROLE) — functional but inconsistent with
     *         freshly-deployed V4 instances.
     *         No-op on a fresh deploy (initializer already advanced the
     *         version past 1, but initialize itself ran setRoleAdmin so the
     *         state is already correct).
     */
    function reinitializeV4() external reinitializer(2) onlyRole(ADMIN_ROLE) {
        _setRoleAdmin(BOND_ROLE, ADMIN_ROLE);
    }

    // ============================== Stake / Claim / Forfeit / Unstake ==============================

    function stake(address to, uint256 amount, bool claim_)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        IERC20Upgradeable(address(ATH)).safeTransferFrom(msg.sender, address(this), amount);
        return _stakeFromInternalBalance(to, amount, claim_);
    }

    function stakeWithGath(address to, uint256 gathAmount, bool claim_)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        require(address(gath) != address(0), "GATH not set");
        require(address(treasury) != address(0), "Treasury not set");
        require(gathAmount > 0, "Zero amount");
        uint256 athEq = gathAmount / GATH_TO_ATH_DECIMALS_SHIFT;
        require(athEq > 0, "Below precision");

        gath.safeTransferFrom(msg.sender, DEAD_ADDRESS, gathAmount);
        treasury.mint(address(this), athEq);

        emit StakedFromGath(msg.sender, gathAmount, athEq);
        return _stakeFromInternalBalance(to, athEq, claim_);
    }

    /**
     * @notice Bond-only entry point. Sends sATH to `to` immediately, bypassing
     *         the per-address warmup queue. Required because the bond
     *         depository deposits every bonder's payout under the same `to`
     *         (== bond address), which would otherwise make `warmupInfo` push
     *         its expiry forward indefinitely and starve the bond of
     *         claimable sATH.
     *
     *         Unlike regular `stake()`, this path *does not* fold the rebase
     *         bounty into the staked amount. The rationale: the depository
     *         records the user's claim as `gonsForBalance(amount)` only, so
     *         any extra sATH minted via `bounty` would be stranded on the
     *         depository as dust forever. We still tick `rebase()` so the
     *         epoch advances normally; the bounty ATH stays in the staking
     *         pool and is recycled into the next epoch's `distribute`,
     *         benefiting all stakers proportionally.
     */
    function stakeForBond(address to, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(BOND_ROLE)
        returns (uint256)
    {
        require(to != address(0), "Zero to");
        require(amount > 0, "Zero amount");
        IERC20Upgradeable(address(ATH)).safeTransferFrom(msg.sender, address(this), amount);
        // Tick the epoch but discard the keeper bounty (see notice above).
        rebase();
        emit StakedForBond(msg.sender, to, amount);
        return _send(to, amount);
    }

    function _stakeFromInternalBalance(address to, uint256 amount, bool claim_) internal returns (uint256) {
        amount = amount + rebase();

        if (claim_ && warmupPeriod == 0) {
            return _send(to, amount);
        }

        Claim memory info_ = warmupInfo[to];
        if (!info_.lock) {
            require(to == msg.sender, "External deposits locked");
        }

        uint256 gonsAdded = sATH.gonsForBalance(amount);
        warmupInfo[to] = Claim({
            deposit: info_.deposit + amount,
            gons: info_.gons + gonsAdded,
            expiry: epochState.number + warmupPeriod,
            lock: info_.lock
        });

        gonsInWarmup = gonsInWarmup + gonsAdded;
        return amount;
    }

    function claim(address to) public override whenNotPaused returns (uint256) {
        Claim memory info_ = warmupInfo[to];
        if (!info_.lock) {
            require(to == msg.sender, "External claims locked");
        }
        if (epochState.number >= info_.expiry && info_.expiry != 0) {
            delete warmupInfo[to];
            gonsInWarmup = gonsInWarmup - info_.gons;
            return _send(to, sATH.balanceForGons(info_.gons));
        }
        return 0;
    }

    function forfeit() external override whenNotPaused returns (uint256) {
        Claim memory info_ = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];
        gonsInWarmup = gonsInWarmup - info_.gons;
        IERC20Upgradeable(address(ATH)).safeTransfer(msg.sender, info_.deposit);
        return info_.deposit;
    }

    function toggleLock() external {
        warmupInfo[msg.sender].lock = !warmupInfo[msg.sender].lock;
    }

    /**
     * @notice V3 carry-over: settles caller's matured warmup into sATH (if any)
     *         before performing the standard unstake. With warmupPeriod > 0
     *         this removes the need for a separate `claim()` call once warmup
     *         has elapsed.
     */
    function unstake(address to, uint256 amount, bool trigger_)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amount_)
    {
        amount_ = amount;
        uint256 bounty;
        if (trigger_) {
            bounty = rebase();
        }

        _autoSettleWarmup(msg.sender);

        IERC20Upgradeable(address(sATH)).safeTransferFrom(msg.sender, address(this), amount);
        amount_ = amount_ + bounty;
        require(amount_ <= ATH.balanceOf(address(this)), "Insufficient ATH balance");
        IERC20Upgradeable(address(ATH)).safeTransfer(to, amount_);
    }

    function _autoSettleWarmup(address user) internal {
        Claim memory info_ = warmupInfo[user];
        if (info_.expiry == 0) return;
        if (epochState.number < info_.expiry) return;
        if (info_.gons == 0) {
            delete warmupInfo[user];
            return;
        }
        delete warmupInfo[user];
        gonsInWarmup = gonsInWarmup - info_.gons;
        uint256 sathAmount = sATH.balanceForGons(info_.gons);
        _send(user, sathAmount);
        emit WarmupAutoSettled(user, info_.gons, sathAmount);
    }

    // ============================== Rebase ==============================

    function rebase() public override returns (uint256 bounty) {
        if (epochState.end <= block.timestamp) {
            sATH.rebase(epochState.distribute, epochState.number);

            epochState.end = epochState.end + epochState.length;
            epochState.number = epochState.number + 1;

            if (address(distributor) != address(0)) {
                distributor.distribute();
                bounty = distributor.retrieveBounty();
            }
            uint256 balance = ATH.balanceOf(address(this));
            uint256 staked = sATH.circulatingSupply();
            if (balance <= staked + bounty) {
                epochState.distribute = 0;
            } else {
                uint256 raw = balance - staked - bounty;
                uint256 cap = (staked * maxRebaseBps) / 10_000;
                if (raw > cap) {
                    epochState.distribute = cap;
                    emit RebaseCapped(raw, cap, staked);
                } else {
                    epochState.distribute = raw;
                }
            }
        }
    }

    // ============================== Internal ==============================

    function _send(address to, uint256 amount) internal returns (uint256) {
        IERC20Upgradeable(address(sATH)).safeTransfer(to, amount);
        return amount;
    }

    // ============================== Views ==============================

    function epoch()
        external
        view
        override
        returns (uint256 length, uint256 number, uint256 end, uint256 distribute)
    {
        return (epochState.length, epochState.number, epochState.end, epochState.distribute);
    }

    function index() external view override returns (uint256) {
        return sATH.index();
    }

    function supplyInWarmup() external view override returns (uint256) {
        return sATH.balanceForGons(gonsInWarmup);
    }

    function secondsToNextEpoch() external view override returns (uint256) {
        if (block.timestamp >= epochState.end) return 0;
        return epochState.end - block.timestamp;
    }

    // ============================== Admin (V1) ==============================

    function setDistributor(address distributor_) external onlyRole(ADMIN_ROLE) {
        distributor = IDistributor(distributor_);
        emit DistributorSet(distributor_);
    }

    function setWarmupLength(uint256 warmupPeriod_) external onlyRole(ADMIN_ROLE) {
        warmupPeriod = warmupPeriod_;
        emit WarmupSet(warmupPeriod_);
    }

    function setTreasury(address treasury_) external onlyRole(ADMIN_ROLE) {
        require(treasury_ != address(0), "Zero treasury");
        treasury = ITreasury(treasury_);
        emit TreasurySet(treasury_);
    }

    function setGath(address gath_) external onlyRole(ADMIN_ROLE) {
        require(gath_ != address(0), "Zero gath");
        gath = IERC20Upgradeable(gath_);
        emit GathSet(gath_);
    }

    // ============================== Admin (V2) ==============================

    function setPaused(bool _p) external onlyRole(ADMIN_ROLE) {
        paused = _p;
        emit Paused(_p);
    }

    function clearEpochDistribute() external onlyRole(ADMIN_ROLE) {
        uint256 previous = epochState.distribute;
        epochState.distribute = 0;
        emit EpochDistributeCleared(previous);
    }

    function rescueATH(address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(to != address(0), "Zero to");
        require(amount <= ATH.balanceOf(address(this)), "Exceeds balance");
        IERC20Upgradeable(address(ATH)).safeTransfer(to, amount);
        emit ATHRescued(to, amount);
    }

    function setMaxRebaseBps(uint256 _bps) external onlyRole(ADMIN_ROLE) {
        require(_bps <= MAX_REBASE_BPS_LIMIT, "Exceeds hard limit");
        uint256 prev = maxRebaseBps;
        maxRebaseBps = _bps;
        emit MaxRebaseBpsSet(prev, _bps);
    }
}
