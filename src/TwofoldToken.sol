// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  TwofoldToken                                                         ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TwofoldToken is ERC20, Ownable {
    constructor(address treasury) ERC20("Twofold", "TWO") Ownable(msg.sender) {
        _mint(treasury, 1_000_000_000e18);
        renounceOwnership();
    }
}
