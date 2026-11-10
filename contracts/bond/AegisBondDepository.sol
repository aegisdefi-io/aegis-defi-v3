// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import "./types/AegisNoteKeeper.sol";

/**
 * @title AegisBondDepository
 * @notice Ports OlympusDAO BondDepository V2 (auto-tuning control variable),
 *         with payout stored in sATH gons (rebase-immune) inside AegisNoteKeeper.
 *         FrontEnd rewards & gOHM dependency removed.
 */
contract AegisBondDepository is Initializable, ReentrancyGuardUpgradeable, AegisNoteKeeper {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant POLICY_ROLE = keccak256("POLICY_ROLE");

    struct Market {
        uint256 capacity;
        IERC20Upgradeable quoteToken;
        bool capacityInQuote;
        uint64 totalDebt;
        uint64 maxPayout;
        uint64 sold;
        uint256 purchased;
    }

    struct Terms {
        bool fixedTerm;
        uint64 controlVariable;
        uint48 vesting;     // seconds (fixedTerm) or absolute timestamp
        uint48 conclusion;  // market end
        uint64 maxDebt;     // circuit breaker
    }

    struct Metadata {
        uint48 lastTune;
        uint48 lastDecay;
        uint48 length;
        uint48 depositInterval;
        uint48 tuneInterval;
        uint8 quoteDecimals;
    }

    struct Adjustment {
        uint64 change;
        uint48 lastAdjustment;
        uint48 timeToAdjusted;
        bool active;
    }

    Market[] public markets;
    Terms[] public terms;
    Metadata[] public metadata;
    mapping(uint256 => Adjustment) public adjustments;
    mapping(address => uint256[]) public marketsForQuote;

    // Per-deposit cap as basis points of the (remaining) market capacity.
    // e.g. 1000 = 10%. A single deposit cannot mint more than this fraction of
    // capacity in one tx — replaces the legacy `depositInterval`-scaled cap so
    // ops can tune cap size independently of tune cadence. If 0 after a fresh
    // upgrade where reinit hasn't run, `_effectiveMaxPayoutBps()` falls back to
    // DEFAULT_MAX_PAYOUT_BPS so the depository keeps functioning.
    uint256 public maxPayoutBps;
    uint256 public constant MAX_PAYOUT_BPS_DENOM = 10_000;
    uint256 public constant DEFAULT_MAX_PAYOUT_BPS = 1_000; // 10%

    event CreateMarket(uint256 indexed id, address indexed baseToken, address indexed quoteToken, uint256 initialPrice);
    event CloseMarket(uint256 indexed id);
    event Bond(uint256 indexed id, uint256 amount, uint256 price);
    event Tuned(uint256 indexed id, uint64 oldControlVariable, uint64 newControlVariable);
    event MaxPayoutBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address ath_,
        address sath_,
        address staking_,
        address treasury_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __AegisNoteKeeper_init(ath_, sath_, staking_, treasury_);

        bytes32 ADMIN = keccak256("ADMIN_ROLE");
        _setRoleAdmin(ADMIN, ADMIN);
        _setRoleAdmin(POLICY_ROLE, ADMIN);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN, admin_);
        _grantRole(POLICY_ROLE, admin_);

        maxPayoutBps = DEFAULT_MAX_PAYOUT_BPS;
    }

    /// @notice Post-upgrade hook: sets `maxPayoutBps` for already-deployed
    /// proxies whose original `initialize()` predated this field. Designed to
    /// be invoked via `ProxyAdmin.upgradeAndCall(...)` atomically with the
    /// upgrade, so it intentionally has **no role gate** — the inner call
    /// runs with `msg.sender == ProxyAdmin`, which does not hold any role.
    /// Replay is prevented by `reinitializer(2)`. Front-running between the
    /// upgrade and this call is impossible because `upgradeAndCall` is one tx.
    /// Subsequent adjustments use `setMaxPayoutBps` (POLICY_ROLE).
    /// Safe to skip entirely — `_effectiveMaxPayoutBps()` falls back to
    /// `DEFAULT_MAX_PAYOUT_BPS` at read time, so bonds keep working.
    function reinitV2(uint256 _maxPayoutBps) external reinitializer(2) {
        require(_maxPayoutBps > 0 && _maxPayoutBps <= MAX_PAYOUT_BPS_DENOM, "Bad bps");
        maxPayoutBps = _maxPayoutBps;
        emit MaxPayoutBpsUpdated(0, _maxPayoutBps);
    }

    /// @notice Adjust the per-deposit cap (bps of capacity). 1000 = 10%.
    function setMaxPayoutBps(uint256 _bps) external onlyRole(POLICY_ROLE) {
        require(_bps > 0 && _bps <= MAX_PAYOUT_BPS_DENOM, "Bad bps");
        uint256 old = maxPayoutBps;
        maxPayoutBps = _bps;
        emit MaxPayoutBpsUpdated(old, _bps);
    }

    function _effectiveMaxPayoutBps() internal view returns (uint256) {
        uint256 v = maxPayoutBps;
        return v == 0 ? DEFAULT_MAX_PAYOUT_BPS : v;
    }

    /* ======== DEPOSIT ======== */

    /**
     * @notice deposit quote tokens in exchange for an ATH-denominated bond
     */
    function deposit(uint256 _id, uint256 _amount, uint256 _maxPrice, address _user)
        external
        nonReentrant
        returns (uint256 payout_, uint256 expiry_, uint256 index_)
    {
        Market storage market = markets[_id];
        Terms memory term = terms[_id];
        uint48 currentTime = uint48(block.timestamp);

        require(currentTime < term.conclusion, "Market concluded");

        _decay(_id, currentTime);

        uint256 price = _marketPrice(_id);
        require(price <= _maxPrice, "Slippage > max price");

        // payout in ATH (9d). 1e18 = ATH decimals (9) + price decimals (9)
        payout_ = ((_amount * 1e18) / price) / (10 ** metadata[_id].quoteDecimals);
        require(payout_ <= market.maxPayout, "Max size exceeded");

        market.capacity = market.capacity - (market.capacityInQuote ? _amount : payout_);

        expiry_ = term.fixedTerm ? term.vesting + currentTime : term.vesting;
        market.purchased = market.purchased + _amount;
        market.sold = market.sold + uint64(payout_);
        market.totalDebt = market.totalDebt + uint64(payout_);

        emit Bond(_id, _amount, price);

        // Route quote token through treasury.deposit() so totalReserves / Deposit
        // event are updated. Treasury mints `value - profit` ATH back to the bond,
        // where `value = tokenValue(quote, _amount)` (1:1 ATH-decimal). The bond
        // owes the user `payout_` ATH (which may differ from value due to bond
        // pricing). We split the math:
        //   - If value >= payout_  : profit = value - payout_ stays in treasury
        //                            as protocol surplus. Bond receives exactly
        //                            payout_ ATH from deposit().
        //   - If value <  payout_  : bond receives `value` ATH from deposit()
        //                            and the depository mints the (payout - value)
        //                            shortfall via REWARD_MANAGER. This handles
        //                            small rounding deficits and intentional
        //                            discount bonds.
        uint256 value = treasury.tokenValue(address(market.quoteToken), _amount);
        market.quoteToken.safeTransferFrom(msg.sender, address(this), _amount);
        // quote token's allowance to treasury was set to max in create(); no per-deposit approve needed.
        if (value >= payout_) {
            treasury.deposit(_amount, address(market.quoteToken), value - payout_);
        } else {
            treasury.deposit(_amount, address(market.quoteToken), 0);
            treasury.mint(address(this), payout_ - value);
        }

        index_ = _addNote(_user, payout_, uint48(expiry_), uint48(_id));

        if (term.maxDebt < market.totalDebt) {
            market.capacity = 0;
            emit CloseMarket(_id);
        } else {
            _tune(_id, currentTime);
        }
    }

    function _decay(uint256 _id, uint48 _time) internal {
        markets[_id].totalDebt = markets[_id].totalDebt - debtDecay(_id);
        metadata[_id].lastDecay = _time;

        if (adjustments[_id].active) {
            Adjustment storage adjustment = adjustments[_id];

            (uint64 adjustBy, uint48 secondsSince, bool stillActive) = _controlDecay(_id);
            terms[_id].controlVariable = terms[_id].controlVariable - adjustBy;

            if (stillActive) {
                adjustment.change = adjustment.change - adjustBy;
                adjustment.timeToAdjusted = adjustment.timeToAdjusted - secondsSince;
                adjustment.lastAdjustment = _time;
            } else {
                adjustment.active = false;
            }
        }
    }

    function _tune(uint256 _id, uint48 _time) internal {
        Metadata memory meta = metadata[_id];

        if (_time >= meta.lastTune + meta.tuneInterval) {
            Market memory market = markets[_id];
            uint256 timeRemaining = terms[_id].conclusion - _time;
            if (timeRemaining == 0) return;
            uint256 price = _marketPrice(_id);
            if (price == 0) return;

            uint256 capacity = market.capacityInQuote
                ? ((market.capacity * 1e18) / price) / (10 ** meta.quoteDecimals)
                : market.capacity;

            // maxPayout = capacity × bps / 10_000. depositInterval no longer
            // gates per-tx size — it only paces `_tune` invocations.
            uint256 mp = (capacity * _effectiveMaxPayoutBps()) / MAX_PAYOUT_BPS_DENOM;
            require(mp <= type(uint64).max, "MaxPayout overflow");
            markets[_id].maxPayout = uint64(mp);

            uint256 targetDebt = (capacity * meta.length) / timeRemaining;
            if (targetDebt == 0) return;

            uint256 ncv = (price * treasury.baseSupply()) / targetDebt;
            require(ncv <= type(uint64).max, "CV overflow");
            uint64 newControlVariable = uint64(ncv);

            emit Tuned(_id, terms[_id].controlVariable, newControlVariable);

            if (newControlVariable >= terms[_id].controlVariable) {
                terms[_id].controlVariable = newControlVariable;
            } else {
                uint64 change = terms[_id].controlVariable - newControlVariable;
                adjustments[_id] = Adjustment(change, _time, meta.tuneInterval, true);
            }
            metadata[_id].lastTune = _time;
        }
    }

    /* ======== CREATE ======== */

    /**
     * @param _market    [capacity, initialPrice (9d ATH), debtBuffer (3d, 1000=1%)]
     * @param _booleans  [capacityInQuote, fixedTerm]
     * @param _terms     [vesting (seconds if fixedTerm) or vestedTimestamp, conclusion timestamp]
     * @param _intervals [depositInterval (s), tuneInterval (s)]
     */
    function create(
        IERC20Upgradeable _quoteToken,
        uint256[3] memory _market,
        bool[2] memory _booleans,
        uint256[2] memory _terms,
        uint32[2] memory _intervals
    ) external onlyRole(POLICY_ROLE) returns (uint256 id_) {
        _validateCreateInputs(_quoteToken, _market, _booleans, _terms, _intervals);

        uint256 secondsToConclusion = _terms[1] - block.timestamp;
        uint256 decimals = IERC20MetadataUpgradeable(address(_quoteToken)).decimals();

        uint64 targetDebt;
        uint64 maxPayout;
        uint256 maxDebt;
        uint256 controlVariable;
        {
            uint256 td = _booleans[0]
                ? ((_market[0] * 1e18) / _market[1]) / 10 ** decimals
                : _market[0];
            require(td > 0, "Zero target debt");
            require(td <= type(uint64).max, "Target debt overflow");
            targetDebt = uint64(td);

            // Per-deposit cap = capacity × bps / 10_000 (target debt == initial
            // capacity in ATH-equivalent units, so use `td` directly).
            uint256 mp = (td * _effectiveMaxPayoutBps()) / MAX_PAYOUT_BPS_DENOM;
            require(mp <= type(uint64).max, "MaxPayout overflow");
            maxPayout = uint64(mp);

            maxDebt = td + ((td * _market[2]) / 1e5);
            require(maxDebt <= type(uint64).max, "MaxDebt overflow");

            controlVariable = (_market[1] * treasury.baseSupply()) / td;
            require(controlVariable > 0, "Zero CV");
            require(controlVariable <= type(uint64).max, "CV overflow");
        }

        id_ = markets.length;

        markets.push(
            Market({
                quoteToken: _quoteToken,
                capacityInQuote: _booleans[0],
                capacity: _market[0],
                totalDebt: targetDebt,
                maxPayout: maxPayout,
                purchased: 0,
                sold: 0
            })
        );

        terms.push(
            Terms({
                fixedTerm: _booleans[1],
                controlVariable: uint64(controlVariable),
                vesting: uint48(_terms[0]),
                conclusion: uint48(_terms[1]),
                maxDebt: uint64(maxDebt)
            })
        );

        metadata.push(
            Metadata({
                lastTune: uint48(block.timestamp),
                lastDecay: uint48(block.timestamp),
                length: uint48(secondsToConclusion),
                depositInterval: _intervals[0],
                tuneInterval: _intervals[1],
                quoteDecimals: uint8(decimals)
            })
        );

        marketsForQuote[address(_quoteToken)].push(id_);

        // One-shot max-approve so deposit() can route quote → treasury without
        // a per-call approve (saves gas; sidesteps OZ 4.9 `safeApprove`
        // non-zero-allowance constraint). Idempotent: subsequent markets on
        // the same quote token re-approve to max if the buffer has shrunk.
        // Uses raw approve() (return bool ignored) — safe for the standard
        // ERC20 reserve tokens whitelisted by the treasury.
        if (_quoteToken.allowance(address(this), address(treasury)) < type(uint256).max / 2) {
            _quoteToken.approve(address(treasury), type(uint256).max);
        }

        emit CreateMarket(id_, address(ATH), address(_quoteToken), _market[1]);
    }

    function _validateCreateInputs(
        IERC20Upgradeable _quoteToken,
        uint256[3] memory _market,
        bool[2] memory _booleans,
        uint256[2] memory _terms,
        uint32[2] memory _intervals
    ) internal view {
        require(treasury.isReserveToken(address(_quoteToken)), "Quote not reserve");
        require(_terms[1] > block.timestamp, "Bad conclusion");
        require(_market[0] > 0, "Zero capacity");
        require(_market[1] > 0, "Zero price");
        require(_market[2] > 0 && _market[2] <= 1_000_000, "Bad buffer");
        require(_intervals[0] > 0 && _intervals[0] < (_terms[1] - block.timestamp), "Bad deposit interval");
        require(_intervals[1] > 0, "Zero tune interval");
        if (_booleans[1]) {
            require(_terms[0] > 0, "Zero vesting");
        } else {
            require(_terms[0] > block.timestamp, "Vested in past");
        }
    }

    function close(uint256 _id) external onlyRole(POLICY_ROLE) {
        terms[_id].conclusion = uint48(block.timestamp);
        markets[_id].capacity = 0;
        emit CloseMarket(_id);
    }

    /* ======== EXTERNAL VIEW ======== */

    function marketPrice(uint256 _id) public view returns (uint256) {
        return (currentControlVariable(_id) * debtRatio(_id)) / (10 ** metadata[_id].quoteDecimals);
    }

    function payoutFor(uint256 _amount, uint256 _id) external view returns (uint256) {
        Metadata memory meta = metadata[_id];
        return ((_amount * 1e18) / marketPrice(_id)) / (10 ** meta.quoteDecimals);
    }

    function debtRatio(uint256 _id) public view returns (uint256) {
        return (currentDebt(_id) * (10 ** metadata[_id].quoteDecimals)) / treasury.baseSupply();
    }

    function currentDebt(uint256 _id) public view returns (uint256) {
        return markets[_id].totalDebt - debtDecay(_id);
    }

    function debtDecay(uint256 _id) public view returns (uint64) {
        Metadata memory meta = metadata[_id];
        uint256 secondsSince = block.timestamp - meta.lastDecay;
        uint256 totalDebt_ = markets[_id].totalDebt;
        uint256 d = (totalDebt_ * secondsSince) / meta.length;
        return uint64(d > totalDebt_ ? totalDebt_ : d);
    }

    function currentControlVariable(uint256 _id) public view returns (uint256) {
        (uint64 decay, , ) = _controlDecay(_id);
        return terms[_id].controlVariable - decay;
    }

    function isLive(uint256 _id) public view returns (bool) {
        return (markets[_id].capacity != 0 && terms[_id].conclusion > block.timestamp);
    }

    function liveMarkets() external view returns (uint256[] memory) {
        uint256 num;
        for (uint256 i = 0; i < markets.length; i++) {
            if (isLive(i)) num++;
        }
        uint256[] memory ids = new uint256[](num);
        uint256 nonce;
        for (uint256 i = 0; i < markets.length; i++) {
            if (isLive(i)) {
                ids[nonce++] = i;
            }
        }
        return ids;
    }

    function liveMarketsFor(address _token) external view returns (uint256[] memory) {
        uint256[] memory mkts = marketsForQuote[_token];
        uint256 num;
        for (uint256 i = 0; i < mkts.length; i++) {
            if (isLive(mkts[i])) num++;
        }
        uint256[] memory ids = new uint256[](num);
        uint256 nonce;
        for (uint256 i = 0; i < mkts.length; i++) {
            if (isLive(mkts[i])) {
                ids[nonce++] = mkts[i];
            }
        }
        return ids;
    }

    function marketsLength() external view returns (uint256) {
        return markets.length;
    }

    /* ======== INTERNAL VIEW ======== */

    function _marketPrice(uint256 _id) internal view returns (uint256) {
        return (terms[_id].controlVariable * _debtRatio(_id)) / (10 ** metadata[_id].quoteDecimals);
    }

    function _debtRatio(uint256 _id) internal view returns (uint256) {
        return (markets[_id].totalDebt * (10 ** metadata[_id].quoteDecimals)) / treasury.baseSupply();
    }

    function _controlDecay(uint256 _id)
        internal
        view
        returns (uint64 decay_, uint48 secondsSince_, bool active_)
    {
        Adjustment memory info = adjustments[_id];
        if (!info.active) return (0, 0, false);
        secondsSince_ = uint48(block.timestamp) - info.lastAdjustment;
        active_ = secondsSince_ < info.timeToAdjusted;
        decay_ = active_ ? (info.change * secondsSince_) / info.timeToAdjusted : info.change;
    }

    // __gap[39] (was 39) − 1 slot consumed by `maxPayoutBps` above.
    uint256[38] private __gap;
}
