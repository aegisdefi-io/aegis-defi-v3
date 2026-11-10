// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

import "../interfaces/IsATH.sol";
import "../interfaces/IStaking.sol";

/**
 * @title sATH
 * @notice Rebasing wrapper of ATH. Ported from OlympusDAO V1 sOlympusERC20 to
 *         Solidity 0.8.24 + OZ Upgradeable. gOHM dependency removed (V1 model with
 *         no separate non-rebasing wrapper).
 */
contract sATH is
    Initializable,
    AccessControlUpgradeable,
    EIP712Upgradeable,
    IERC20Upgradeable,
    IERC20PermitUpgradeable,
    IsATH
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 private constant MAX_UINT256 = type(uint256).max;
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5_000_000 * 10 ** 9;
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);
    uint256 private constant MAX_SUPPLY = ~uint128(0);

    struct Rebase {
        uint256 epoch;
        uint256 rebase; // 18 decimals
        uint256 totalStakedBefore;
        uint256 totalStakedAfter;
        uint256 amountRebased;
        uint256 index;
        uint256 blockNumberOccured;
    }

    string private _name;
    string private _symbol;

    address public stakingContract;
    address public treasury;
    uint256 public INDEX; // gons units, set once

    uint256 private _totalSupplyValue;
    uint256 private _gonsPerFragment;
    mapping(address => uint256) private _gonBalances;
    mapping(address => mapping(address => uint256)) private _allowedValue;
    mapping(address => uint256) public override debtBalances;

    Rebase[] public rebases;

    mapping(address => uint256) private _nonces;

    event LogSupply(uint256 indexed epoch, uint256 totalSupply);
    event LogRebase(uint256 indexed epoch, uint256 rebase, uint256 index);
    event LogStakingContractUpdated(address stakingContract);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, address treasury_, uint256 initialIndex_) external initializer {
        __AccessControl_init();
        __EIP712_init("sATH", "1");

        require(admin_ != address(0), "Zero admin");
        require(treasury_ != address(0), "Zero treasury");

        _name = "Staked Aegis";
        _symbol = "sATH";

        _totalSupplyValue = INITIAL_FRAGMENTS_SUPPLY;
        _gonsPerFragment = TOTAL_GONS / _totalSupplyValue;
        INDEX = gonsForBalance(initialIndex_);

        treasury = treasury_;

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    /**
     * @notice Set the staking contract once. Mints the initial gons balance to staking.
     */
    function setStakingContract(address staking_) external onlyRole(ADMIN_ROLE) {
        require(stakingContract == address(0), "Already set");
        require(staking_ != address(0), "Zero staking");
        stakingContract = staking_;
        _gonBalances[staking_] = TOTAL_GONS;
        emit Transfer(address(0), staking_, _totalSupplyValue);
        emit LogStakingContractUpdated(staking_);
    }

    function setTreasury(address treasury_) external onlyRole(ADMIN_ROLE) {
        require(treasury_ != address(0), "Zero treasury");
        treasury = treasury_;
    }

    // ============================== Rebase ==============================

    function rebase(uint256 profit_, uint256 epoch_) external override returns (uint256) {
        require(msg.sender == stakingContract, "Only staking");
        uint256 rebaseAmount;
        uint256 circulatingSupply_ = circulatingSupply();
        if (profit_ == 0) {
            emit LogSupply(epoch_, _totalSupplyValue);
            emit LogRebase(epoch_, 0, index());
            return _totalSupplyValue;
        } else if (circulatingSupply_ > 0) {
            rebaseAmount = (profit_ * _totalSupplyValue) / circulatingSupply_;
        } else {
            rebaseAmount = profit_;
        }

        _totalSupplyValue = _totalSupplyValue + rebaseAmount;

        if (_totalSupplyValue > MAX_SUPPLY) {
            _totalSupplyValue = MAX_SUPPLY;
        }

        _gonsPerFragment = TOTAL_GONS / _totalSupplyValue;

        _storeRebase(circulatingSupply_, profit_, epoch_);

        return _totalSupplyValue;
    }

    function _storeRebase(uint256 previousCirculating_, uint256 profit_, uint256 epoch_) internal {
        uint256 rebasePercent = previousCirculating_ == 0 ? 0 : (profit_ * 1e18) / previousCirculating_;
        rebases.push(
            Rebase({
                epoch: epoch_,
                rebase: rebasePercent,
                totalStakedBefore: previousCirculating_,
                totalStakedAfter: circulatingSupply(),
                amountRebased: profit_,
                index: index(),
                blockNumberOccured: block.number
            })
        );

        emit LogSupply(epoch_, _totalSupplyValue);
        emit LogRebase(epoch_, rebasePercent, index());
    }

    // ============================== ERC20 ===============================

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return 9;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupplyValue;
    }

    function balanceOf(address who) public view override returns (uint256) {
        if (_gonsPerFragment == 0) return 0;
        return _gonBalances[who] / _gonsPerFragment;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 gonValue = value * _gonsPerFragment;
        _gonBalances[msg.sender] = _gonBalances[msg.sender] - gonValue;
        _gonBalances[to] = _gonBalances[to] + gonValue;
        require(balanceOf(msg.sender) >= debtBalances[msg.sender], "Debt: cannot transfer amount");
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 currentAllowance = _allowedValue[from][msg.sender];
        require(currentAllowance >= value, "ERC20: insufficient allowance");
        unchecked {
            _allowedValue[from][msg.sender] = currentAllowance - value;
        }
        emit Approval(from, msg.sender, _allowedValue[from][msg.sender]);

        uint256 gonValue = value * _gonsPerFragment;
        _gonBalances[from] = _gonBalances[from] - gonValue;
        _gonBalances[to] = _gonBalances[to] + gonValue;

        require(balanceOf(from) >= debtBalances[from], "Debt: cannot transfer amount");
        emit Transfer(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(msg.sender, spender, _allowedValue[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        uint256 oldValue = _allowedValue[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _approve(msg.sender, spender, 0);
        } else {
            _approve(msg.sender, spender, oldValue - subtractedValue);
        }
        return true;
    }

    function allowance(address owner_, address spender) public view override returns (uint256) {
        return _allowedValue[owner_][spender];
    }

    function _approve(address owner_, address spender, uint256 value) internal {
        _allowedValue[owner_][spender] = value;
        emit Approval(owner_, spender, value);
    }

    // ============================== Permit ==============================

    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        require(block.timestamp <= deadline, "ERC20Permit: expired deadline");
        uint256 currentNonce = _nonces[owner_];
        bytes32 structHash = keccak256(
            abi.encode(_PERMIT_TYPEHASH, owner_, spender, value, currentNonce, deadline)
        );
        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSAUpgradeable.recover(hash, v, r, s);
        require(signer == owner_, "ERC20Permit: invalid signature");
        _nonces[owner_] = currentNonce + 1;
        _approve(owner_, spender, value);
    }

    function nonces(address owner_) public view override returns (uint256) {
        return _nonces[owner_];
    }

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view override returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============================== Debt ================================

    function changeDebt(uint256 amount, address debtor, bool add) external override {
        require(msg.sender == treasury, "Only treasury");
        if (add) {
            debtBalances[debtor] = debtBalances[debtor] + amount;
        } else {
            debtBalances[debtor] = debtBalances[debtor] - amount;
        }
        require(debtBalances[debtor] <= balanceOf(debtor), "sATH: insufficient balance");
    }

    // ============================== Views ===============================

    function gonsForBalance(uint256 amount) public view override returns (uint256) {
        return amount * _gonsPerFragment;
    }

    function balanceForGons(uint256 gons) public view override returns (uint256) {
        if (_gonsPerFragment == 0) return 0;
        return gons / _gonsPerFragment;
    }

    function circulatingSupply() public view override returns (uint256) {
        if (stakingContract == address(0)) {
            return 0;
        }
        uint256 stakingBal = balanceOf(stakingContract);
        uint256 inWarmup = IStaking(stakingContract).supplyInWarmup();
        // _totalSupply - balance(staking) + supplyInWarmup
        return _totalSupplyValue - stakingBal + inWarmup;
    }

    function index() public view override returns (uint256) {
        return balanceForGons(INDEX);
    }

    uint256[35] private __gap;
}
