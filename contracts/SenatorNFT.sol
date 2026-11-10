// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";

contract SenatorNFT is Initializable, ERC721Upgradeable, AccessControlUpgradeable {
    using StringsUpgradeable for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint256 private _nextId;
    string private _baseTokenURI;

    event BaseURISet(string baseURI);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_, string memory baseURI_) external initializer {
        __ERC721_init("Aegis Senator", "AEGS");
        __AccessControl_init();

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        _nextId = 1;
        _baseTokenURI = baseURI_;
    }

    function mintBatch(address to, uint256 count) external onlyRole(MINTER_ROLE) {
        uint256 id = _nextId;
        for (uint256 i = 0; i < count; i++) {
            _mint(to, id);
            unchecked { id++; }
        }
        _nextId = id;
    }

    function totalMinted() external view returns (uint256) {
        return _nextId - 1;
    }

    function setBaseURI(string calldata baseURI_) external onlyRole(ADMIN_ROLE) {
        _baseTokenURI = baseURI_;
        emit BaseURISet(baseURI_);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    uint256[46] private __gap;
}
