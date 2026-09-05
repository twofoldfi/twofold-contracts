// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {VoteToken} from "../src/VoteToken.sol";
import {PoolVoting} from "../src/PoolVoting.sol";

contract TwoMock2 is ERC20 {
    constructor() ERC20("Twofold", "TWO") {
        _mint(msg.sender, 1_000_000_000e18);
    }
}

contract PoolVotingTest is Test {
    TwoMock2 two;
    VoteToken vtwo;
    PoolVoting voting;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    string[] opts;

    function setUp() public {
        vm.warp(1_756_600_000);
        two = new TwoMock2();
        vtwo = new VoteToken(IERC20(address(two)));
        voting = new PoolVoting(IERC5805(address(vtwo)), operator);
        two.transfer(alice, 1_000e18);
        two.transfer(bob, 1_000e18);
        vm.startPrank(alice);
        two.approve(address(vtwo), type(uint256).max);
        vtwo.depositFor(alice, 300e18);
        vm.stopPrank();
        vm.startPrank(bob);
        two.approve(address(vtwo), type(uint256).max);
        vtwo.depositFor(bob, 100e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 10);
        opts.push("MSFT/USDG");
        opts.push("COIN/USDG");
        opts.push("HOOD/USDG");
    }

    function _propose() internal returns (uint256) {
        vm.prank(operator);
        return voting.propose(
            "Next pool", opts,
            uint48(block.timestamp + 60), uint48(block.timestamp + 3 days)
        );
    }

    function test_onlyOwnerProposes() public {
        vm.prank(alice);
        vm.expectRevert();
        voting.propose("x", opts, uint48(block.timestamp + 60), uint48(block.timestamp + 3 days));
    }

    function test_proposeStoresAndSnapshotsBeforeCreation() public {
        uint256 id = _propose();
        assertEq(id, 0);
        assertEq(voting.proposalCount(), 1);
        (, uint48 snapshot,,, bool canceled) = voting.proposal(id);
        assertEq(snapshot, uint48(block.timestamp - 1));
        assertFalse(canceled);
        assertEq(voting.options(id).length, 3);
        assertEq(voting.tally(id).length, 3);
    }

    function test_proposeBoundsRejected() public {
        string[] memory one = new string[](1);
        one[0] = "solo";
        vm.startPrank(operator);
        vm.expectRevert(PoolVoting.BadOptions.selector);
        voting.propose("x", one, uint48(block.timestamp + 60), uint48(block.timestamp + 120));
        vm.expectRevert(PoolVoting.BadWindow.selector);
        voting.propose("x", opts, uint48(block.timestamp - 1), uint48(block.timestamp + 120));
        vm.expectRevert(PoolVoting.BadWindow.selector);
        voting.propose("x", opts, uint48(block.timestamp + 120), uint48(block.timestamp + 60));
        vm.stopPrank();
    }

    function test_voteTalliesPastWeight() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        voting.vote(id, 1);
        assertEq(voting.tally(id)[1], 300e18);
        (bool voted, uint16 option, uint256 weight) = voting.receipts(id, alice);
        assertTrue(voted);
        assertEq(option, 1);
        assertEq(weight, 300e18);
    }

    function test_revoteMovesFullWeight() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + 61);
        vm.startPrank(alice);
        voting.vote(id, 1);
        voting.vote(id, 2);
        vm.stopPrank();
        assertEq(voting.tally(id)[1], 0);
        assertEq(voting.tally(id)[2], 300e18);
    }

    function test_wrapAfterSnapshotHasNoWeight() public {
        uint256 id = _propose();
        address carol = makeAddr("carol");
        two.transfer(carol, 500e18);
        vm.startPrank(carol);
        two.approve(address(vtwo), type(uint256).max);
        vtwo.depositFor(carol, 500e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 61);
        vm.prank(carol);
        vm.expectRevert(PoolVoting.NoWeight.selector);
        voting.vote(id, 0);
    }

    function test_voteOutsideWindowReverts() public {
        uint256 id = _propose();
        vm.prank(alice);
        vm.expectRevert(PoolVoting.NotOpen.selector);
        voting.vote(id, 0);
        vm.warp(block.timestamp + 4 days);
        vm.prank(alice);
        vm.expectRevert(PoolVoting.NotOpen.selector);
        voting.vote(id, 0);
    }

    function test_badOptionReverts() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        vm.expectRevert(PoolVoting.BadOption.selector);
        voting.vote(id, 3);
    }

    function test_cancelBlocksVotingAndIsOwnerOnlyBeforeEnd() public {
        uint256 id = _propose();
        vm.prank(alice);
        vm.expectRevert();
        voting.cancel(id);
        vm.prank(operator);
        voting.cancel(id);
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        vm.expectRevert(PoolVoting.Canceled.selector);
        voting.vote(id, 0);
        vm.warp(block.timestamp + 4 days);
        vm.prank(operator);
        vm.expectRevert(PoolVoting.NotOpen.selector);
        voting.cancel(id);
    }

    function test_cancelTwiceRevertsCanceled() public {
        uint256 id = _propose();
        vm.startPrank(operator);
        voting.cancel(id);
        vm.expectRevert(PoolVoting.Canceled.selector);
        voting.cancel(id);
        vm.stopPrank();
    }

    function test_missingProposalReverts() public {
        vm.prank(alice);
        vm.expectRevert(PoolVoting.NoProposal.selector);
        voting.vote(7, 0);
    }

    function test_windowShorterThanMinReverts() public {
        vm.prank(operator);
        vm.expectRevert(PoolVoting.BadWindow.selector);
        voting.propose(
            "x", opts, uint48(block.timestamp + 60), uint48(block.timestamp + 60 + 1 days - 1)
        );
    }

    function test_windowExactlyMinAccepted() public {
        vm.prank(operator);
        voting.propose(
            "x", opts, uint48(block.timestamp + 60), uint48(block.timestamp + 60 + 1 days)
        );
    }

    function test_twoVotersIndependentTallies() public {
        uint256 id = _propose();
        vm.warp(block.timestamp + 61);
        vm.prank(alice);
        voting.vote(id, 0);
        vm.prank(bob);
        voting.vote(id, 2);
        assertEq(voting.tally(id)[0], 300e18);
        assertEq(voting.tally(id)[2], 100e18);
    }
}
