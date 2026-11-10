// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IATH.sol";
import "../interfaces/ITreasury.sol";

/**
 * @title AegisTreasury
 * @notice Single mint gate for ATH inflation. Holds USDC (and other reserve tokens),
 *         mints ATH on behalf of authorized REWARD_MANAGER_ROLE callers
 *         (Distributor, BondDepository, etc.). No `excessReserves`
 *         backing requirement (intentional inflation model). No debt logic
 *         (V1-style simplification).
 */
contract AegisTreasury is Initializable, AccessControlUpgradeable, ITreasury {
    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice may push reserve tokens to treasury via deposit() (e.g. BondDepository)
    bytes32 public constant RESERVE_DEPOSITOR_ROLE = keccak256("RESERVE_DEPOSITOR_ROLE");
    /// @notice may pull reserve tokens via withdraw() (emergency only — typically multisig)
    bytes32 public constant RESERVE_SPENDER_ROLE = keccak256("RESERVE_SPENDER_ROLE");
    /// @notice may call mint() to inflate ATH supply
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");

    IATH public ATH;

    mapping(address => bool) public override isReserveToken;
    mapping(address => uint8) public reserveTokenDecimals;
    address[] public reserveTokens;

    /// @notice cumulative reserve value in ATH decimals (9). Bookkeeping only — does NOT gate mint.
    uint256 public totalReserves;

    event Deposit(address indexed token, uint256 amount, uint256 value);
    event Withdrawal(address indexed token, uint256 amount, address indexed to);
    event Minted(address indexed caller, address indexed recipient, uint256 amount);
    event ReserveTokenSet(address indexed token, uint8 decimals_, bool enabled);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, address ath_) external initializer {
        __AccessControl_init();
        require(admin_ != address(0), "Zero admin");
        require(ath_ != address(0), "Zero ATH");

        ATH = IATH(ath_);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(RESERVE_DEPOSITOR_ROLE, ADMIN_ROLE);
        _setRoleAdmin(RESERVE_SPENDER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REWARD_MANAGER_ROLE, ADMIN_ROLE);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ============================== Reserve management ==============================

    function setReserveToken(address token, bool enabled) external onlyRole(ADMIN_ROLE) {
        require(token != address(0), "Zero token");
        if (enabled && !isReserveToken[token]) {
            uint8 dec = IERC20MetadataUpgradeable(token).decimals();
            reserveTokenDecimals[token] = dec;
            isReserveToken[token] = true;
            reserveTokens.push(token);
            emit ReserveTokenSet(token, dec, true);
        } else if (!enabled && isReserveToken[token]) {
            isReserveToken[token] = false;
            // leave reserveTokens array as-is (avoid O(n) shuffles); enumeration callers must check isReserveToken.
            emit ReserveTokenSet(token, reserveTokenDecimals[token], false);
        }
    }

    /**
     * @notice deposit a reserve token in exchange for ATH (mint = value - profit).
     * @dev    `_profit` is the portion the protocol keeps; remainder is minted to the caller.
     */
    function deposit(uint256 amount, address token, uint256 profit)
        external
        override
        onlyRole(RESERVE_DEPOSITOR_ROLE)
        returns (uint256 send_)
    {
        require(isReserveToken[token], "Not reserve");
        IERC20MetadataUpgradeable(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 value = tokenValue(token, amount);
        require(value >= profit, "Profit > value");
        send_ = value - profit;
        if (send_ > 0) {
            ATH.mint(msg.sender, send_);
        }
        totalReserves = totalReserves + value;
        emit Deposit(token, amount, value);
    }

    /**
     * @notice mint ATH directly (no reserve change). Single inflation gate.
     */
    function mint(address recipient, uint256 amount) external override onlyRole(REWARD_MANAGER_ROLE) {
        ATH.mint(recipient, amount);
        emit Minted(msg.sender, recipient, amount);
    }

    /**
     * @notice emergency withdraw of a reserve token. Use sparingly.
     */
    function withdraw(uint256 amount, address token) external override onlyRole(RESERVE_SPENDER_ROLE) {
        require(isReserveToken[token], "Not reserve");
        uint256 value = tokenValue(token, amount);
        if (totalReserves >= value) {
            totalReserves = totalReserves - value;
        } else {
            totalReserves = 0;
        }
        IERC20MetadataUpgradeable(token).safeTransfer(msg.sender, amount);
        emit Withdrawal(token, amount, msg.sender);
    }

    // ============================== Views ==============================

    /**
     * @notice convert raw `amount` of `token` into ATH-decimal-equivalent value (1:1 ratio).
     * @dev    Aegis assumes USDC ≈ ATH for accounting; the BondDepository auto-tunes
     *         the actual market price. Override via upgrade if a price oracle is desired.
     */
    function tokenValue(address token, uint256 amount) public view override returns (uint256) {
        return amount * (10 ** ATH.decimals()) / (10 ** reserveTokenDecimals[token]);
    }

    function baseSupply() external view override returns (uint256) {
        return ATH.totalSupply();
    }

    function reserveTokenAt(uint256 i) external view returns (address) {
        return reserveTokens[i];
    }

    function reserveTokensLength() external view returns (uint256) {
        return reserveTokens.length;
    }

    uint256[44] private __gap;
}
