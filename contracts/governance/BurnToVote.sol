// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

import "../interfaces/IATH.sol";
import "../interfaces/IsATH.sol";
import "../interfaces/IStaking.sol";
import "../interfaces/IGsATHStaking.sol";
import "../interfaces/IDistributorInfo.sol";

/**
 * @title BurnToVote
 * @notice Rate vote where the ballot is the staked asset itself. Inside an
 *         admin-opened window a holder votes with sATH; the sATH is removed
 *         from circulation and the voter receives gsATH 1:1.
 *
 *         "Burn" on-chain: sATH has no burn function, so the vote contract
 *         unstakes the sATH through the main Staking (`unstake(this, amt, false)`
 *         returns exactly `amt` ATH and the sATH goes back to Staking's
 *         unissued pool, leaving `circulatingSupply`). The ATH is then handed to
 *         the gsATH vault as backing. Net: sATH circulating −amt, gsATH +amt.
 *
 *         Tally: every SATH_PER_STEP burned in a window = one step of
 *         RATE_PER_STEP on the distributor rate, capped by the window's
 *         `maxSteps`. Votes beyond the cap are still accepted (the voter still
 *         receives gsATH) but add no step.
 *
 *         Execution is NOT done by this contract. After the window closes the
 *         Master Safe submits `AegisDistributorV2.setAdjustment` using the
 *         parameters from `suggestedAdjustment()`,
 *         so no new role is granted on the live distributor.
 */
contract BurnToVote is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant WINDOW_MANAGER_ROLE = keccak256("WINDOW_MANAGER_ROLE");

    /// @notice sATH burned per rate step (9 decimals).
    uint256 public constant SATH_PER_STEP = 10_000 * 1e9;
    /// @notice Distributor rate numerator added per step (100 = +0.01 pp per epoch).
    uint256 public constant RATE_PER_STEP = 100;
    /// @notice Mirror of AegisDistributorV2.MAX_ADJUST_DELTA_BPS (per-call step cap).
    uint256 public constant MAX_ADJUST_DELTA_BPS = 1000;
    /// @notice Distributor info[] index of the main staking recipient.
    uint256 public constant RATE_INDEX = 0;

    struct Window {
        uint64 start;
        uint64 end;
        bool closed;
        uint256 maxSteps;
        uint256 burned;
        uint256 voters;
        uint256 rateAtClose;
    }

    // ============================== Storage (do not reorder) ==============================

    IsATH public sATH;
    IATH public ATH;
    IStaking public staking;
    IGsATHStaking public vault;
    IDistributorInfo public distributor;

    Window[] public windows;
    mapping(uint256 => mapping(address => uint256)) public voted;

    uint256[43] private __gap;

    // ============================== Events ==============================

    event WindowOpened(uint256 indexed id, uint64 start, uint64 end, uint256 maxSteps);
    event WindowClosed(uint256 indexed id, uint256 burned, uint256 steps, uint256 rateAtClose);
    event Voted(uint256 indexed id, address indexed voter, uint256 amount, uint256 windowBurned, uint256 steps);

    // ============================== Errors ==============================

    error ZeroAddress();
    error ZeroAmount();
    error WindowNotOpen();
    error WindowActive();
    error NoWindow();
    error BadWindow();
    error UnstakeMismatch();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address sath_,
        address ath_,
        address staking_,
        address vault_,
        address distributor_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        if (
            admin_ == address(0) || sath_ == address(0) || ath_ == address(0) || staking_ == address(0)
                || vault_ == address(0) || distributor_ == address(0)
        ) revert ZeroAddress();

        sATH = IsATH(sath_);
        ATH = IATH(ath_);
        staking = IStaking(staking_);
        vault = IGsATHStaking(vault_);
        distributor = IDistributorInfo(distributor_);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(WINDOW_MANAGER_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(WINDOW_MANAGER_ROLE, admin_);
    }

    // ============================== Window admin ==============================

    /// @notice Open a voting window. Only one window may be live at a time. A
    ///         previous window that expired without `closeWindow` is closed here
    ///         (rate snapshot + event) so no window is ever left half-open.
    function openWindow(uint64 start, uint64 end, uint256 maxSteps)
        external
        onlyRole(WINDOW_MANAGER_ROLE)
        returns (uint256 id)
    {
        if (end <= start || end <= block.timestamp || maxSteps == 0) revert BadWindow();
        if (windows.length > 0) {
            uint256 lastId = windows.length - 1;
            Window storage last = windows[lastId];
            if (!last.closed) {
                if (block.timestamp <= last.end) revert WindowActive();
                _close(lastId);
            }
        }
        id = windows.length;
        windows.push(
            Window({start: start, end: end, closed: false, maxSteps: maxSteps, burned: 0, voters: 0, rateAtClose: 0})
        );
        emit WindowOpened(id, start, end, maxSteps);
    }

    /// @notice Close the latest window (also usable before `end` as an emergency stop)
    ///         and snapshot the distributor rate for the execution script.
    function closeWindow() external onlyRole(WINDOW_MANAGER_ROLE) {
        if (windows.length == 0) revert NoWindow();
        uint256 id = windows.length - 1;
        if (windows[id].closed) revert WindowNotOpen();
        _close(id);
    }

    function _close(uint256 id) internal {
        Window storage w = windows[id];
        w.closed = true;
        (uint256 rate,) = distributor.info(RATE_INDEX);
        w.rateAtClose = rate;
        emit WindowClosed(id, w.burned, steps(id), rate);
    }

    // ============================== Voting ==============================

    /// @notice Vote with `amount` sATH (requires prior `sATH.approve(this, amount)`).
    function vote(uint256 amount) external nonReentrant {
        _vote(msg.sender, amount);
    }

    /// @notice Vote using an EIP-2612 permit on sATH (single transaction). If the
    ///         permit was already consumed (e.g. front-run) the existing allowance
    ///         is used instead.
    function voteWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        nonReentrant
    {
        try IERC20PermitUpgradeable(address(sATH)).permit(msg.sender, address(this), amount, deadline, v, r, s) {}
            catch {}
        _vote(msg.sender, amount);
    }

    function _vote(address voter, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (!isOpen()) revert WindowNotOpen();
        uint256 id = windows.length - 1;
        Window storage w = windows[id];

        // 1. Pull sATH from the voter.
        IERC20Upgradeable(address(sATH)).safeTransferFrom(voter, address(this), amount);

        // 2. Remove it from circulation via the main Staking; receive ATH 1:1.
        uint256 before = ATH.balanceOf(address(this));
        IERC20Upgradeable(address(sATH)).safeApprove(address(staking), amount);
        uint256 got = staking.unstake(address(this), amount, false);
        if (got != amount || ATH.balanceOf(address(this)) - before != amount) revert UnstakeMismatch();

        // 3. Hand the ATH to the vault as backing; the vault mints gsATH 1:1.
        IERC20Upgradeable(address(ATH)).safeApprove(address(vault), amount);
        vault.mintFor(voter, amount);

        // 4. Tally.
        if (voted[id][voter] == 0) w.voters += 1;
        voted[id][voter] += amount;
        w.burned += amount;

        emit Voted(id, voter, amount, w.burned, steps(id));
    }

    // ============================== Views ==============================

    function windowCount() external view returns (uint256) {
        return windows.length;
    }

    function currentWindowId() public view returns (uint256) {
        if (windows.length == 0) revert NoWindow();
        return windows.length - 1;
    }

    function isOpen() public view returns (bool) {
        if (windows.length == 0) return false;
        Window storage w = windows[windows.length - 1];
        return !w.closed && block.timestamp >= w.start && block.timestamp <= w.end;
    }

    function votedOf(uint256 id, address voter) external view returns (uint256) {
        return voted[id][voter];
    }

    /// @notice Rate steps secured by window `id`: floor(burned / SATH_PER_STEP), capped at maxSteps.
    function steps(uint256 id) public view returns (uint256) {
        Window storage w = windows[id];
        uint256 raw = w.burned / SATH_PER_STEP;
        return raw > w.maxSteps ? w.maxSteps : raw;
    }

    /// @notice True once the window's maxSteps is reached; further votes add no step.
    function capReached(uint256 id) external view returns (bool) {
        Window storage w = windows[id];
        return w.burned / SATH_PER_STEP >= w.maxSteps;
    }

    /// @notice Parameters for the Safe's `setAdjustment(index, add, step, target)`.
    ///         `step` is capped against the LIVE rate (what setAdjustment checks);
    ///         `baseRate` is the live rate or, when an upward adjustment is still
    ///         phasing in, its target — so executing this window never silently
    ///         drops the remainder of the previous one (setAdjustment overwrites).
    ///         `epochsToReach` is how many distribute() ticks the phased step needs.
    function suggestedAdjustment(uint256 id)
        external
        view
        returns (
            uint256 index_,
            bool add,
            uint256 step,
            uint256 target,
            uint256 stepsCount,
            uint256 baseRate,
            uint256 epochsToReach
        )
    {
        (uint256 liveRate,) = distributor.info(RATE_INDEX);
        baseRate = liveRate;
        (bool pendingAdd, uint256 pendingRate, uint256 pendingTarget) = distributor.adjustments(RATE_INDEX);
        if (pendingRate != 0 && pendingAdd && pendingTarget > liveRate) baseRate = pendingTarget;
        stepsCount = steps(id);
        uint256 delta = RATE_PER_STEP * stepsCount;
        uint256 cap = (liveRate * MAX_ADJUST_DELTA_BPS) / 10_000;
        if (cap == 0) cap = MAX_ADJUST_DELTA_BPS;
        step = delta < cap ? delta : cap;
        target = baseRate + delta;
        index_ = RATE_INDEX;
        add = true;
        uint256 climb = target - liveRate;
        epochsToReach = step == 0 ? 0 : (climb + step - 1) / step;
    }
}
