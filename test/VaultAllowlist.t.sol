// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VaultAllowlist} from "../src/VaultAllowlist.sol";

contract VaultAllowlistTest is Test {
    VaultAllowlist list;
    address owner = makeAddr("owner");
    address rando = makeAddr("rando");
    address vault = makeAddr("vault");

    function setUp() public {
        list = new VaultAllowlist(owner);
    }

    function test_defaultsToNotAllowed() public view {
        assertFalse(list.isAllowed(vault));
    }

    function test_ownerCanAllowAndRevoke() public {
        vm.prank(owner);
        list.setAllowed(vault, true);
        assertTrue(list.isAllowed(vault));
        vm.prank(owner);
        list.setAllowed(vault, false);
        assertFalse(list.isAllowed(vault));
    }

    function test_nonOwnerCannotSet() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        list.setAllowed(vault, true);
    }

    function test_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit VaultAllowlist.VaultAllowedSet(vault, true);
        vm.prank(owner);
        list.setAllowed(vault, true);
    }
}
