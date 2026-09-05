// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  Registry                                                             ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VaultAllowlist} from "./VaultAllowlist.sol";

interface IFactoryProvenance {
    function isFromFactory(address deployed) external view returns (bool);
}

contract Registry is Ownable2Step {
    enum OperatorMode { SelfOperated, ProtocolOperated }

    struct PoolListing {
        address hook;
        bytes32 poolId;
        address currency0;
        address currency1;
        uint24 fee;
        address vault0;
        address vault1;
        OperatorMode mode;
        bool verified;
        bool active;
    }

    error AlreadyListed();
    error NotListed();
    error ZeroHook();

    event PoolListed(bytes32 indexed poolId, address indexed hook, bool verified);
    event PoolActiveSet(bytes32 indexed poolId, bool active);

    IFactoryProvenance public immutable factory;
    VaultAllowlist public immutable allowlist;

    mapping(bytes32 => PoolListing) internal _pools;
    bytes32[] internal _ids;

    constructor(address owner_, address factory_, address allowlist_) Ownable(owner_) {
        factory = IFactoryProvenance(factory_);
        allowlist = VaultAllowlist(allowlist_);
    }

    function listPool(PoolListing calldata l) external onlyOwner {
        if (l.hook == address(0)) revert ZeroHook();
        if (_pools[l.poolId].hook != address(0)) revert AlreadyListed();
        PoolListing memory stored = l;
        stored.verified = factory.isFromFactory(l.hook)
            && (l.vault0 == address(0) || allowlist.isAllowed(l.vault0))
            && (l.vault1 == address(0) || allowlist.isAllowed(l.vault1));
        _pools[l.poolId] = stored;
        _ids.push(l.poolId);
        emit PoolListed(l.poolId, l.hook, stored.verified);
    }

    function setActive(bytes32 poolId, bool active) external onlyOwner {
        if (_pools[poolId].hook == address(0)) revert NotListed();
        _pools[poolId].active = active;
        emit PoolActiveSet(poolId, active);
    }

    function getPool(bytes32 poolId) external view returns (PoolListing memory listing) {
        listing = _pools[poolId];
        if (listing.hook == address(0)) return listing;
        listing.verified = factory.isFromFactory(listing.hook)
            && (listing.vault0 == address(0) || allowlist.isAllowed(listing.vault0))
            && (listing.vault1 == address(0) || allowlist.isAllowed(listing.vault1));
    }

    function allPoolIds() external view returns (bytes32[] memory) {
        return _ids;
    }
}
