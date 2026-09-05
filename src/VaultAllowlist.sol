// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  VaultAllowlist                                                       ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract VaultAllowlist is Ownable2Step {
    mapping(address vault => bool allowed) public isAllowed;

    event VaultAllowedSet(address indexed vault, bool allowed);

    constructor(address owner_) Ownable(owner_) {}

    function setAllowed(address vault, bool allowed) external onlyOwner {
        isAllowed[vault] = allowed;
        emit VaultAllowedSet(vault, allowed);
    }
}
