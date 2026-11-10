// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/IGsATH.sol";

/**
 * @title GsATH — Governance sATH
 * @notice Non-transferable rebasing receipt for sATH that was removed from
 *         circulation in a Burn-to-Vote window. Minted 1:1 by the gsATH vault
 *         (`GsATHStaking`), which also drives the rebase and burns on unstake.
 *
 *         Accounting is share based (balance = shares × totalPooled / totalShares)
 *         so the token can start from zero supply and grow with each rebase
 *         without a fixed gons constant. `index()` is 1e9 at launch and scales
 *         with the accumulated premium rebases, mirroring sATH's index semantics.
 *
 *         Transferability: every ERC-20 movement other than mint (`from = 0`)
 *         and burn (`to = 0`) reverts, and allowances are never recorded, so
 *         DEX listing, exchange deposit and peer-to-peer transfer are not
 *         possible from any wallet type. The ERC-20 views and `Transfer`
 *         events are kept so wallets can display balances.
 *
 *         Not to be confused with gATH (the ILO participation token).
 */
contract GsATH is Initializable, AccessControlUpgradeable, IGsATH {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 private constant INDEX_ONE = 1e9;

    // ============================== Storage (do not reorder) ==============================

    /// @notice The vault allowed to mint / burn / rebase. Set once.
    address public staking;

    uint256 private _totalShares;
    uint256 private _totalPooled;
    mapping(address => uint256) private _shares;

    uint256[46] private __gap;

    // ============================== Events ==============================

    event StakingSet(address staking);
    event LogRebase(uint256 indexed epoch, uint256 profit, uint256 index);

    // ============================== Errors ==============================

    error NonTransferable();
    error OnlyStaking();
    error AlreadySet();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance();

    modifier onlyStaking() {
        if (msg.sender != staking) revert OnlyStaking();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) external initializer {
        __AccessControl_init();
        if (admin_ == address(0)) revert ZeroAddress();

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /// @notice One-time wiring of the vault (same pattern as sATH.setStakingContract).
    function setStaking(address staking_) external onlyRole(ADMIN_ROLE) {
        if (staking != address(0)) revert AlreadySet();
        if (staking_ == address(0)) revert ZeroAddress();
        staking = staking_;
        emit StakingSet(staking_);
    }

    // ============================== Vault entry points ==============================

    function mint(address to, uint256 amount) external override onlyStaking returns (uint256 sharesMinted) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (_totalShares == 0 || _totalPooled == 0) {
            // Fresh pool (or a pool that was fully exited): 1 share = 1 unit.
            // Any pooled dust left behind by a full exit is folded into this mint.
            sharesMinted = amount;
            _totalPooled = 0;
        } else {
            sharesMinted = (amount * _totalShares) / _totalPooled;
        }
        if (sharesMinted == 0) revert ZeroAmount();

        _totalShares += sharesMinted;
        _totalPooled += amount;
        _shares[to] += sharesMinted;

        emit Transfer(address(0), to, amount);
    }

    /// @dev Shares are rounded UP so a holder can never withdraw more value than
    ///      their shares represent; `amount` must not exceed `balanceOf(from)`.
    function burn(address from, uint256 amount) external override onlyStaking returns (uint256 sharesBurned) {
        if (amount == 0) revert ZeroAmount();
        uint256 held = _shares[from];
        if (held == 0 || _totalPooled == 0) revert InsufficientBalance();

        sharesBurned = _ceilDiv(amount * _totalShares, _totalPooled);
        if (sharesBurned > held || amount > _totalPooled) revert InsufficientBalance();

        _shares[from] = held - sharesBurned;
        _totalShares -= sharesBurned;
        _totalPooled -= amount;
        if (_totalShares == 0) _totalPooled = 0;

        emit Transfer(from, address(0), amount);
    }

    /// @notice Burn every share of `from`; returns the exact value released.
    function burnAll(address from) external override onlyStaking returns (uint256 amountBurned) {
        uint256 held = _shares[from];
        if (held == 0) revert InsufficientBalance();

        amountBurned = (held * _totalPooled) / _totalShares;

        _shares[from] = 0;
        _totalShares -= held;
        _totalPooled -= amountBurned;
        if (_totalShares == 0) _totalPooled = 0;

        emit Transfer(from, address(0), amountBurned);
    }

    /// @notice Add `profit` (ATH units, already minted into the vault) to the pool.
    function rebase(uint256 profit, uint256 epoch) external override onlyStaking returns (uint256) {
        if (profit > 0 && _totalShares > 0) {
            _totalPooled += profit;
        } else {
            profit = 0;
        }
        emit LogRebase(epoch, profit, index());
        return _totalPooled;
    }

    // ============================== ERC-20 views ==============================

    function name() public pure returns (string memory) {
        return "Governance sATH";
    }

    function symbol() public pure returns (string memory) {
        return "gsATH";
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalPooled;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_totalShares == 0) return 0;
        return (_shares[account] * _totalPooled) / _totalShares;
    }

    function sharesOf(address account) external view override returns (uint256) {
        return _shares[account];
    }

    function totalShares() external view override returns (uint256) {
        return _totalShares;
    }

    /// @notice Value of one initial share, 1e9 at launch.
    function index() public view override returns (uint256) {
        if (_totalShares == 0) return INDEX_ONE;
        return (_totalPooled * INDEX_ONE) / _totalShares;
    }

    function allowance(address, address) public pure override returns (uint256) {
        return 0;
    }

    // ============================== Transfers: disabled ==============================

    function transfer(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function increaseAllowance(address, uint256) public pure returns (bool) {
        revert NonTransferable();
    }

    function decreaseAllowance(address, uint256) public pure returns (bool) {
        revert NonTransferable();
    }

    // ============================== Internal ==============================

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        if (a == 0) return 0;
        return (a - 1) / b + 1;
    }
}
