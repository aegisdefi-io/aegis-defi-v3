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
 * @title AegisStaking
 * @notice Ports OlympusDAO V1 Staking. Single rebasing token (sATH); gOHM/wrap/unwrap removed.
 *         GATH 1:1 entry point preserved (`stakeWithGath`).
 *
 *         Handles day-to-day stake/rebase mechanics. External callers may invoke
 *         `stake()` / `unstake()` on behalf of users.
 */
contract AegisStaking is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IStaking
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Burn sink for GATH (this contract has no MINTER on GATH; transfer to dead is the cheapest cross-version-safe burn).
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Decimal-shift between GATH (18d) and ATH (9d). 1 GATH (1e18) ≡ 1 ATH (1e9).
    uint256 public constant GATH_TO_ATH_DECIMALS_SHIFT = 1e9;

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

    IATH public ATH;
    IsATH public sATH;
    IDistributor public distributor;

    /// @notice Used to mint ATH directly into this contract when users deposit GATH instead of ATH.
    ITreasury public treasury;

    /// @notice Aegis governance token (ILO bond reward). Burning GATH here trades it 1:1 for newly-minted ATH.
    IERC20Upgradeable public gath;

    Epoch public epochState;

    mapping(address => Claim) public warmupInfo;
    uint256 public warmupPeriod;
    uint256 private gonsInWarmup;

    event DistributorSet(address distributor);
    event WarmupSet(uint256 warmup);
    event TreasurySet(address treasury);
    event GathSet(address gath);
    event StakedFromGath(address indexed user, uint256 gathAmount, uint256 athEquiv);

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
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ============================== Stake / Claim / Forfeit / Unstake ==============================

    function stake(address to, uint256 amount, bool claim_)
        external
        override
        nonReentrant
        returns (uint256)
    {
        IERC20Upgradeable(address(ATH)).safeTransferFrom(msg.sender, address(this), amount);
        return _stakeFromInternalBalance(to, amount, claim_);
    }

    /**
     * @notice Stake `gathAmount` of GATH (ILO governance token) instead of ATH.
     *         GATH is burned (sent to dead address) and the equivalent ATH is minted
     *         into this contract via Treasury, then routed through the regular stake flow.
     *
     *         Conversion: 1 GATH (1e18) ≡ 1 ATH (1e9). Reverts if `gathAmount < 1e9`.
     */
    function stakeWithGath(address to, uint256 gathAmount, bool claim_)
        external
        nonReentrant
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
     * @dev Shared body of `stake` / `stakeWithGath` — assumes the relevant amount
     *      of ATH is already sitting on this contract.
     */
    function _stakeFromInternalBalance(address to, uint256 amount, bool claim_) internal returns (uint256) {
        amount = amount + rebase(); // include keeper bounty if rebase fired

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

    function claim(address to) public override returns (uint256) {
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

    function forfeit() external override returns (uint256) {
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
        returns (uint256 amount_)
    {
        amount_ = amount;
        uint256 bounty;
        if (trigger_) {
            bounty = rebase();
        }
        IERC20Upgradeable(address(sATH)).safeTransferFrom(msg.sender, address(this), amount);
        amount_ = amount_ + bounty;
        require(amount_ <= ATH.balanceOf(address(this)), "Insufficient ATH balance");
        IERC20Upgradeable(address(ATH)).safeTransfer(to, amount_);
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
                epochState.distribute = balance - staked - bounty;
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

    // ============================== Admin ==============================

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

    uint256[35] private __gap;
}
