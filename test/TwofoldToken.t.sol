// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwofoldToken} from "../src/TwofoldToken.sol";

interface IOwnableView {
    function owner() external view returns (address);
    function renounceOwnership() external;
    function transferOwnership(address newOwner) external;
}

contract TwofoldTokenTest is Test {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function test_fixedSupplyMintedToTreasury() public {
        address treasury = makeAddr("treasury");
        TwofoldToken t = new TwofoldToken(treasury);
        assertEq(t.totalSupply(), 1_000_000_000e18);
        assertEq(t.balanceOf(treasury), 1_000_000_000e18);
        assertEq(t.decimals(), 18);
    }

    function test_nameAndSymbol() public {
        TwofoldToken t = new TwofoldToken(makeAddr("treasury"));
        assertEq(t.name(), "Twofold");
        assertEq(t.symbol(), "TWO");
    }

    function test_ownerIsZeroAfterDeploy() public {
        TwofoldToken t = new TwofoldToken(makeAddr("treasury"));
        assertEq(IOwnableView(address(t)).owner(), address(0));
    }

    function test_renounceEventFiresDuringConstruction() public {
        address treasury = makeAddr("treasury");
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(address(this), address(0));
        new TwofoldToken(treasury);
    }

    function test_renounceOwnershipRevertsForEveryone() public {
        TwofoldToken t = new TwofoldToken(makeAddr("treasury"));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        IOwnableView(address(t)).renounceOwnership();
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        IOwnableView(address(t)).renounceOwnership();
    }

    function test_transferOwnershipRevertsForEveryone() public {
        TwofoldToken t = new TwofoldToken(makeAddr("treasury"));
        address rando = makeAddr("rando");
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        IOwnableView(address(t)).transferOwnership(rando);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", rando));
        IOwnableView(address(t)).transferOwnership(rando);
    }

    function test_noMintSelectorExists() public {
        TwofoldToken t = new TwofoldToken(makeAddr("treasury"));
        (bool ok,) = address(t).call(abi.encodeWithSelector(0x40c10f19, address(this), 1e18));
        assertFalse(ok, "mint(address,uint256) must not exist");
        assertEq(t.totalSupply(), 1_000_000_000e18);
    }
}
