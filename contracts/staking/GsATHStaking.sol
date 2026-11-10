// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "../interfaces/IATH.sol";
import "../interfaces/IGsATH.sol";
import "../interfaces/IGsATHStaking.sol";
import "../interfaces/IDistributorInfo.sol";
import "../interfaces/IStaking.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title GsATHStaking — gsATH vault with built-in distribution
 * @notice Holds the ATH that backs gsATH 1:1, pays the premium rebase every
 *         main-staking epoch and handles unstaking with a burned exit fee.
 *
 *         Why no separate distributor: `AegisDistributorV2.distribute()` is
 *         callable by the main Staking only and sizes every recipient on
 *         `sATH.circulatingSupply()`. Registering gsATH there would over-mint.
 *         This vault therefore mints its own reward through
 *         `treasury.mint(this, gsATH.totalSupply() × (sATHRate + premium) / 1e6)`,
 *         reading the live sATH rate from the distributor so a passed vote
 *         raises gsATH yield automatically.
 *
 *         Epoch clock = the main Staking epoch number. `rebase()` pays one
 *         rebase per main epoch that has passed since `lastRebasedEpoch`
 *         (bounded catch-up), so gsATH never drifts from sATH's schedule and
 *         stalls together with it. The vault never calls `staking.rebase()`.
 *
 *         Invariant: ATH.balanceOf(this) ≥ gsATH.totalSupply() (see `backing()`).
 *         There is deliberately no rescue path for ATH.
 *
 *         Liveness: `unstake` must never be blocked by the reward leg. A failing
 *         `treasury.mint` (role revoked, treasury replaced, ATH minter revoked) or
 *         a failing `distributor.info` read makes that epoch's reward 0
 *         (`RebaseSkipped`) instead of reverting, so holders can always exit
 *         against the ATH the vault already holds. `mintFor` is strict instead:
 *         it refuses to mint while epochs are still unpaid (`CatchUpFirst`), so
 *         a late voter can never be paid for epochs before their deposit.
 */
contract GsATHStaking is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IGsATHStaking
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Burn-to-Vote contract: the only caller allowed to mint gsATH.
    bytes32 public constant VOTE_ROLE = keccak256("VOTE_ROLE");

    uint256 public constant RATE_DENOMINATOR = 1_000_000;
    uint256 public constant MAX_PREMIUM_RATE = 1000; // +0.1% per epoch
    uint256 public constant MAX_FEE_BPS = 1000; // 10%
    uint256 public constant MAX_CATCHUP = 16; // epochs paid per rebase() call
    /// @notice Hard ceiling on (sATH rate + premium) per epoch: 1%. Bounds the
    ///         vault's use of REWARD_MANAGER_ROLE even if the distributor is
    ///         mis-set or mis-pointed (live sATH rate is 0.24%).
    uint256 public constant MAX_TOTAL_RATE = 10_000;

    // ============================== Storage (do not reorder) ==============================

    IATH public ATH;
    IGsATH public gsATH;
    IStaking public staking;
    IDistributorInfo public distributor;
    ITreasury public treasury;

    /// @notice `distributor.info(rateIndex)` is the sATH rate gsATH tracks (0 = main staking).
    uint256 public rateIndex;
    /// @notice Added to the sATH rate per epoch (100 = +0.01 percentage points).
    uint256 public premiumRate;
    /// @notice Exit fee in basis points, burned in ATH (500 = 5%).
    uint256 public feeBps;
    /// @notice Main-staking epoch number up to which gsATH has been rebased.
    uint256 public lastRebasedEpoch;

    bool public paused;

    uint256 public totalFeesBurned;
    uint256 public totalMinted;

    uint256[38] private __gap;

    // ============================== Events ==============================

    event Minted(address indexed voter, uint256 amount, uint256 shares);
    event Unstaked(address indexed user, uint256 gsathAmount, uint256 athOut, uint256 feeBurned);
    event Rebased(uint256 indexed epoch, uint256 profit, uint256 rate);
    /// @notice The reward for `epoch` could not be minted (treasury/distributor failure); paid as 0.
    event RebaseSkipped(uint256 indexed epoch, uint256 profitSkipped);
    event PremiumRateSet(uint256 premiumRate);
    event FeeBpsSet(uint256 feeBps);
    event Paused(bool state);
    event DistributorSet(address distributor);
    event RateIndexSet(uint256 rateIndex);

    // ============================== Errors ==============================

    error IsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error PremiumTooHigh();
    error FeeTooHigh();
    error BadRateIndex();
    error CatchUpFirst();

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address ath_,
        address gsath_,
        address staking_,
        address distributor_,
        address treasury_,
        uint256 premiumRate_,
        uint256 feeBps_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (
            admin_ == address(0) || ath_ == address(0) || gsath_ == address(0) || staking_ == address(0)
                || distributor_ == address(0) || treasury_ == address(0)
        ) revert ZeroAddress();
        if (premiumRate_ > MAX_PREMIUM_RATE) revert PremiumTooHigh();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();

        ATH = IATH(ath_);
        gsATH = IGsATH(gsath_);
        staking = IStaking(staking_);
        distributor = IDistributorInfo(distributor_);
        treasury = ITreasury(treasury_);
        premiumRate = premiumRate_;
        feeBps = feeBps_;

        (, uint256 number,,) = staking.epoch();
        lastRebasedEpoch = number;

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(VOTE_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ============================== Vote entry ==============================

    /// @notice Pull `amount` ATH from the vote contract as backing and mint the
    ///         same amount of gsATH to `voter`. Settles pending rebases first and
    ///         refuses to mint while any epoch is still unpaid (more than
    ///         MAX_CATCHUP pending → call `rebase()` first), so a late voter can
    ///         neither dilute existing holders nor be paid for epochs before
    ///         their deposit.
    function mintFor(address voter, uint256 amount)
        external
        override
        onlyRole(VOTE_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256 sharesMinted)
    {
        if (voter == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _rebase();
        if (pendingEpochs() != 0) revert CatchUpFirst();

        IERC20Upgradeable(address(ATH)).safeTransferFrom(msg.sender, address(this), amount);
        sharesMinted = gsATH.mint(voter, amount);
        totalMinted += amount;

        emit Minted(voter, amount, sharesMinted);
    }

    // ============================== Unstake ==============================

    /// @notice Burn gsATH and receive ATH minus the exit fee, which is burned.
    ///         Pass `type(uint256).max` to exit the whole position exactly.
    ///         Settles up to MAX_CATCHUP pending epochs first; if more are
    ///         pending the exiting holder forfeits the rest (call `rebase()`
    ///         beforehand to collect everything). Never reverts on reward failure.
    function unstake(uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 athOut)
    {
        if (amount == 0) revert ZeroAmount();

        _rebase();

        uint256 burned;
        if (amount == type(uint256).max) {
            burned = gsATH.burnAll(msg.sender);
        } else {
            gsATH.burn(msg.sender, amount);
            burned = amount;
        }
        if (burned == 0) revert ZeroAmount();

        uint256 fee = (burned * feeBps) / 10_000;
        athOut = burned - fee;

        if (fee > 0) {
            ATH.burn(fee);
            totalFeesBurned += fee;
        }
        IERC20Upgradeable(address(ATH)).safeTransfer(msg.sender, athOut);

        emit Unstaked(msg.sender, burned, athOut, fee);
    }

    // ============================== Rebase ==============================

    /// @notice Pay one premium rebase per main-staking epoch elapsed since the
    ///         last call (at most MAX_CATCHUP per call). Anyone may call; the
    ///         API's epoch job calls it right after the main rotation.
    function rebase() public override returns (uint256 epochsProcessed) {
        return _rebase();
    }

    function _rebase() internal returns (uint256 epochsProcessed) {
        (, uint256 mainEpoch,,) = staking.epoch();
        uint256 last = lastRebasedEpoch;
        if (last >= mainEpoch) return 0;

        while (last < mainEpoch && epochsProcessed < MAX_CATCHUP) {
            unchecked {
                ++last;
                ++epochsProcessed;
            }
            uint256 rate = currentRate();
            uint256 profit = (gsATH.totalSupply() * rate) / RATE_DENOMINATOR;
            if (profit > 0) {
                // Reward leg is best-effort: a treasury failure must not trap
                // holders behind `unstake` (see contract doc). The epoch still
                // advances, paid as 0, and the skip is logged for the operator.
                try treasury.mint(address(this), profit) {}
                catch {
                    emit RebaseSkipped(last, profit);
                    profit = 0;
                }
            }
            gsATH.rebase(profit, last);
            emit Rebased(last, profit, rate);
        }
        lastRebasedEpoch = last;
    }

    // ============================== Views ==============================

    /// @notice Per-epoch gsATH rate = live sATH rate + premium (numerator over
    ///         1e6), clamped to MAX_TOTAL_RATE. Returns 0 (no reward, exits keep
    ///         working) if the distributor read reverts.
    function currentRate() public view override returns (uint256) {
        try distributor.info(rateIndex) returns (uint256 rate, address) {
            uint256 total = rate + premiumRate;
            return total > MAX_TOTAL_RATE ? MAX_TOTAL_RATE : total;
        } catch {
            return 0;
        }
    }

    /// @notice Main epochs that have rotated but are not yet paid to gsATH.
    function pendingEpochs() public view override returns (uint256) {
        (, uint256 mainEpoch,,) = staking.epoch();
        return mainEpoch > lastRebasedEpoch ? mainEpoch - lastRebasedEpoch : 0;
    }

    /// @notice Timestamp of the next main-staking epoch end (= next gsATH rebase).
    function nextRebaseAt() external view returns (uint256) {
        (,, uint256 end,) = staking.epoch();
        return end;
    }

    /// @notice ATH held minus gsATH supply. Must never be negative.
    function backing() external view returns (int256) {
        return int256(ATH.balanceOf(address(this))) - int256(gsATH.totalSupply());
    }

    function previewUnstake(uint256 amount) external view override returns (uint256 athOut, uint256 fee) {
        fee = (amount * feeBps) / 10_000;
        athOut = amount - fee;
    }

    // ============================== Admin ==============================

    function setPremiumRate(uint256 premiumRate_) external onlyRole(ADMIN_ROLE) {
        if (premiumRate_ > MAX_PREMIUM_RATE) revert PremiumTooHigh();
        premiumRate = premiumRate_;
        emit PremiumRateSet(premiumRate_);
    }

    function setFeeBps(uint256 feeBps_) external onlyRole(ADMIN_ROLE) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        emit FeeBpsSet(feeBps_);
    }

    /// @notice Pauses mintFor/unstake only; rebase() keeps running.
    function setPaused(bool state) external onlyRole(ADMIN_ROLE) {
        paused = state;
        emit Paused(state);
    }

    /// @notice Re-point the distributor; the current `rateIndex` must resolve to
    ///         the main staking on the new one.
    function setDistributor(address distributor_) external onlyRole(ADMIN_ROLE) {
        if (distributor_ == address(0)) revert ZeroAddress();
        (, address recipient) = IDistributorInfo(distributor_).info(rateIndex);
        if (recipient != address(staking)) revert BadRateIndex();
        distributor = IDistributorInfo(distributor_);
        emit DistributorSet(distributor_);
    }

    function setRateIndex(uint256 rateIndex_) external onlyRole(ADMIN_ROLE) {
        (, address recipient) = distributor.info(rateIndex_);
        if (recipient != address(staking)) revert BadRateIndex();
        rateIndex = rateIndex_;
        emit RateIndexSet(rateIndex_);
    }
}
