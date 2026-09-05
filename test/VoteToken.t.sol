// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VoteToken} from "../src/VoteToken.sol";

contract TwoMock is ERC20 {
    constructor() ERC20("Twofold", "TWO") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

contract VoteTokenTest is Test {
    TwoMock two;
    VoteToken vtwo;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_756_600_000); // real-ish timestamp; checkpoints key on time
        two = new TwoMock();
        vtwo = new VoteToken(IERC20(address(two)));
        two.transfer(alice, 1_000e18);
        two.transfer(bob, 1_000e18);
        vm.prank(alice);
        two.approve(address(vtwo), type(uint256).max);
        vm.prank(bob);
        two.approve(address(vtwo), type(uint256).max);
    }

    function test_metadata() public view {
        assertEq(vtwo.name(), "Twofold Votes");
        assertEq(vtwo.symbol(), "vTWO");
        assertEq(vtwo.decimals(), 18);
        assertEq(address(vtwo.underlying()), address(two));
    }

    function test_clockIsTimestamp() public view {
        assertEq(vtwo.clock(), uint48(block.timestamp));
        assertEq(vtwo.CLOCK_MODE(), "mode=timestamp");
    }

    function test_depositMints1to1AndSelfDelegates() public {
        vm.prank(alice);
        vtwo.depositFor(alice, 100e18);
        assertEq(vtwo.balanceOf(alice), 100e18);
        assertEq(two.balanceOf(address(vtwo)), 100e18);
        assertEq(vtwo.delegates(alice), alice);
        assertEq(vtwo.getVotes(alice), 100e18);
    }

    function test_depositDoesNotOverrideExplicitDelegation() public {
        vm.startPrank(alice);
        vtwo.depositFor(alice, 10e18);
        vtwo.delegate(bob);
        vtwo.depositFor(alice, 10e18);
        vm.stopPrank();
        assertEq(vtwo.delegates(alice), bob);
        assertEq(vtwo.getVotes(bob), 20e18);
        assertEq(vtwo.getVotes(alice), 0);
    }

    function test_withdrawBurnsAndReturnsUnderlying() public {
        vm.startPrank(alice);
        vtwo.depositFor(alice, 100e18);
        vtwo.withdrawTo(alice, 40e18);
        vm.stopPrank();
        assertEq(vtwo.balanceOf(alice), 60e18);
        assertEq(two.balanceOf(alice), 940e18);
        assertEq(vtwo.getVotes(alice), 60e18);
    }

    function test_pastVotesSnapshotImmuneToLaterMoves() public {
        vm.prank(alice);
        vtwo.depositFor(alice, 100e18);
        // external call defeats via-ir block.timestamp rematerialization under vm.warp
        uint256 snap = vtwo.clock();
        vm.warp(snap + 100);
        vm.prank(alice);
        vtwo.transfer(bob, 100e18);
        assertEq(vtwo.getPastVotes(alice, snap), 100e18);
        assertEq(vtwo.getPastVotes(bob, snap), 0);
    }

    function test_transferMovesVotingPowerWhenBothSelfDelegated() public {
        vm.prank(alice);
        vtwo.depositFor(alice, 100e18);
        vm.prank(bob);
        vtwo.depositFor(bob, 1e18);
        vm.prank(alice);
        vtwo.transfer(bob, 50e18);
        assertEq(vtwo.getVotes(alice), 50e18);
        assertEq(vtwo.getVotes(bob), 51e18);
    }

    function test_depositForThirdPartySelfDelegatesRecipient() public {
        vm.prank(alice);
        vtwo.depositFor(bob, 25e18);
        assertEq(vtwo.delegates(bob), bob);
        assertEq(vtwo.getVotes(bob), 25e18);
    }
}
