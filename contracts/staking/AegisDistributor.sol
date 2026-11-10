// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IATH.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IDistributor.sol";

/**
 * @title AegisDistributor
 * @notice Ports OlympusDAO V1 StakingDistributor.
 *         Emits per-epoch reward by minting `ATH.totalSupply * rate / 1_000_000`
 *         to each `recipient` (typically the AegisStaking contract).
 *         `setAdjustment` allows governance to drift the rate toward a target.
 */
contract AegisDistributor is Initializable, AccessControlUpgradeable, IDistributor {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Dedicated role for `setAdjustment` so a Governor + Timelock can drive the
    ///         emission rate (Fed-style point-dot) without holding the broader ADMIN_ROLE.
    bytes32 public constant RATE_MANAGER_ROLE = keccak256("RATE_MANAGER_ROLE");

    uint256 public constant RATE_DENOMINATOR = 1_000_000;
    /// @notice Hard upper bound for a single setAdjustment delta (anti-fat-finger). Bps over current rate.
    uint256 public constant MAX_ADJUST_DELTA_BPS = 1000; // 10% of current rate per call

    struct Info {
        uint256 rate;       // numerator over RATE_DENOMINATOR
        address recipient;
    }

    struct Adjust {
        bool add;
        uint256 rate;
        uint256 target;
    }

    IATH public ATH;
    ITreasury public treasury;
    address public staking;

    Info[] public info;
    mapping(uint256 => Adjust) public adjustments;
    uint256 public override bounty;

    event Distributed(uint256 indexed index_, address indexed recipient, uint256 amount);
    event RecipientAdded(uint256 indexed index_, address indexed recipient, uint256 rate);
    event RecipientRemoved(uint256 indexed index_, address indexed recipient);
    event AdjustmentSet(uint256 indexed index_, bool add, uint256 rate, uint256 target);
    event BountySet(uint256 bounty);
    event StakingSet(address staking);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin_,
        address treasury_,
        address ath_,
        address staking_
    ) external initializer {
        __AccessControl_init();
        require(admin_ != address(0), "Zero admin");
        require(treasury_ != address(0), "Zero treasury");
        require(ath_ != address(0), "Zero ATH");

        treasury = ITreasury(treasury_);
        ATH = IATH(ath_);
        staking = staking_; // may be set later via setStaking

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(RATE_MANAGER_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        // Bootstrap: admin holds RATE_MANAGER_ROLE initially. Transfer to a Governor +
        // Timelock contract once governance is live, then optionally revoke from admin.
        _grantRole(RATE_MANAGER_ROLE, admin_);
    }

    // ============================== Public ==============================

    function distribute() external override {
        require(msg.sender == staking, "Only staking");
        uint256 len = info.length;
        for (uint256 i = 0; i < len; i++) {
            if (info[i].rate > 0 && info[i].recipient != address(0)) {
                uint256 amount = nextRewardAt(info[i].rate);
                treasury.mint(info[i].recipient, amount);
                emit Distributed(i, info[i].recipient, amount);
                _adjust(i);
            }
        }
    }

    function retrieveBounty() external override returns (uint256) {
        require(msg.sender == staking, "Only staking");
        if (bounty > 0) {
            treasury.mint(staking, bounty);
        }
        return bounty;
    }

    function _adjust(uint256 index_) internal {
        Adjust memory adjustment = adjustments[index_];
        if (adjustment.rate == 0) return;

        if (adjustment.add) {
            info[index_].rate = info[index_].rate + adjustment.rate;
            if (info[index_].rate >= adjustment.target) {
                adjustments[index_].rate = 0;
                info[index_].rate = adjustment.target;
            }
        } else {
            if (info[index_].rate > adjustment.rate) {
                info[index_].rate = info[index_].rate - adjustment.rate;
            } else {
                info[index_].rate = 0;
            }
            if (info[index_].rate <= adjustment.target) {
                adjustments[index_].rate = 0;
                info[index_].rate = adjustment.target;
            }
        }
    }

    // ============================== Views ==============================

    function nextRewardAt(uint256 _rate) public view override returns (uint256) {
        return (ATH.totalSupply() * _rate) / RATE_DENOMINATOR;
    }

    function nextRewardFor(address _recipient) external view override returns (uint256) {
        uint256 reward;
        uint256 len = info.length;
        for (uint256 i = 0; i < len; i++) {
            if (info[i].recipient == _recipient) {
                reward = reward + nextRewardAt(info[i].rate);
            }
        }
        return reward;
    }

    function infoLength() external view returns (uint256) {
        return info.length;
    }

    // ============================== Admin ==============================

    function setStaking(address staking_) external onlyRole(ADMIN_ROLE) {
        require(staking_ != address(0), "Zero staking");
        staking = staking_;
        emit StakingSet(staking_);
    }

    function setBounty(uint256 _bounty) external override onlyRole(ADMIN_ROLE) {
        require(_bounty <= 2e9, "Too much");
        bounty = _bounty;
        emit BountySet(_bounty);
    }

    function addRecipient(address _recipient, uint256 _rewardRate)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        require(_recipient != address(0), "Zero recipient");
        require(_rewardRate <= RATE_DENOMINATOR, "Rate too high");
        info.push(Info({recipient: _recipient, rate: _rewardRate}));
        emit RecipientAdded(info.length - 1, _recipient, _rewardRate);
    }

    function removeRecipient(uint256 _index) external override onlyRole(ADMIN_ROLE) {
        require(_index < info.length, "Bad index");
        require(info[_index].recipient != address(0), "Already removed");
        emit RecipientRemoved(_index, info[_index].recipient);
        info[_index].recipient = address(0);
        info[_index].rate = 0;
    }

    function setAdjustment(uint256 _index, bool _add, uint256 _rate, uint256 _target)
        external
        override
        onlyRole(RATE_MANAGER_ROLE)
    {
        require(_index < info.length, "Bad index");
        require(info[_index].recipient != address(0), "Recipient removed");
        // Hard delta cap to prevent fat-finger drastic changes
        uint256 cap = (info[_index].rate * MAX_ADJUST_DELTA_BPS) / 10000;
        if (cap == 0) cap = MAX_ADJUST_DELTA_BPS; // still cap if rate==0
        require(_rate <= cap, "Delta too large");
        if (!_add) {
            require(_rate <= info[_index].rate, "Cannot decrease >current");
        }
        adjustments[_index] = Adjust({add: _add, rate: _rate, target: _target});
        emit AdjustmentSet(_index, _add, _rate, _target);
    }

    uint256[42] private __gap;
}
