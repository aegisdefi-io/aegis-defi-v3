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
 * @title AegisStakingV5
 * @notice Storage-compatible upgrade of AegisStakingV4.
 *
 *         **Sole behavioural change vs V4**: epoch rebase yield is now anchored
 *         to the Distributor's rate instead of the staking pool's accidental
 *         (balance - circulatingSupply) surplus.
 *
 *         V4 problem: `epochState.distribute` was derived from
 *           raw = ATH.balanceOf(this) - sATH.circulatingSupply() - bounty
 *         which made the next-epoch rebase oscillate between 0 (deficit) and
 *         `maxRebaseBps` cap (windfall) depending on pool solvency snapshots.
 *         Stakers whose warmup ended during a deficit window received zero
 *         yield even though the Distributor was actively minting.
 *
 *         V5 fix: distribute mirrors exactly what the Distributor will mint
 *         next epoch — `distributor.nextRewardFor(this)` — i.e. the rate-based
 *         reward already committed in Distributor.info. Mint amount and rebase
 *         amount become equal by construction every epoch, so:
 *           - no deficit-driven zero rebases
 *           - no surplus-driven cap rebases (windfalls)
 *           - delta (ATH balance - sATH circulating) stays proportional
 *
 *         Storage layout: byte-identical to V4. `maxRebaseBps` is retained as
 *         legacy state (and its setter remains for ABI/monitoring stability)
 *         but no longer participates in the rebase math.
 *
 *         Solvency assumption: as long as Distributor.distribute mints at least
 *         `nextRewardFor(this)` per tick (which is what V2 does by construction),
 *         the pool stays at-or-above 1:1 backing of sATH by ATH. Only an
 *         explicit admin `rescueATH` can break this invariant.
 */
contract AegisStakingV5 is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IStaking
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
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

    // ============================== Storage (V2 additions, kept for V3/V4/V5) ==============================

    bool public paused;
    /// @notice Legacy cap from V2..V4. Retained for storage layout and ABI
    ///         (setMaxRebaseBps stays callable) but ignored by V5's rebase().
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

    /// @notice Carried over from V4. No state change is required for the V4 → V5
    ///         upgrade; the implementation can be swapped without a reinitializer.
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

    /// @notice V5: next-epoch distribute equals the Distributor's committed
    ///         reward for this contract. This makes mint and rebase symmetric
    ///         and removes the balance-derived variability that produced 0%
    ///         and capped-rate epochs in V4.
    function rebase() public override returns (uint256 bounty) {
        if (epochState.end <= block.timestamp) {
            sATH.rebase(epochState.distribute, epochState.number);

            epochState.end = epochState.end + epochState.length;
            epochState.number = epochState.number + 1;

            if (address(distributor) != address(0)) {
                distributor.distribute();
                bounty = distributor.retrieveBounty();
                epochState.distribute = distributor.nextRewardFor(address(this));
            } else {
                epochState.distribute = 0;
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

    /// @notice Legacy V2..V4 setter retained for ABI/monitoring compatibility.
    ///         V5's rebase() ignores this value; the field remains writable so
    ///         dashboards that read it continue to function.
    function setMaxRebaseBps(uint256 _bps) external onlyRole(ADMIN_ROLE) {
        require(_bps <= MAX_REBASE_BPS_LIMIT, "Exceeds hard limit");
        uint256 prev = maxRebaseBps;
        maxRebaseBps = _bps;
        emit MaxRebaseBpsSet(prev, _bps);
    }
}
