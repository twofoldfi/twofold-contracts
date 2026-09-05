// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
// Halmos: PoolVoting tally-conservation properties. The votes token is
// mocked so getPastVotes/clock are fully symbolic-friendly instead of
// depending on ERC20Votes checkpoint internals (covered separately by
// VoteToken's own unit suite). Properties: a first vote moves the tally sum
// by exactly the voter's weight, a re-vote moves it by zero (the old weight
// is subtracted before the new weight is added), and cancel never touches
// any tally entry.
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {PoolVoting} from "../../src/PoolVoting.sol";

contract HalmosMockVotes {
    mapping(address => mapping(uint256 => uint256)) public votesAt;
    uint48 public t;

    function setClock(uint48 _t) external {
        t = _t;
    }

    function setPastVotes(address account, uint256 timepoint, uint256 weight) external {
        votesAt[account][timepoint] = weight;
    }

    function clock() external view returns (uint48) {
        return t;
    }

    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        return votesAt[account][timepoint];
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 0;
    }

    function delegates(address) external pure returns (address) {
        return address(0);
    }

    function delegate(address) external {}

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external {}
}

contract PoolVotingSymbolicTest is Test {
    PoolVoting voting;
    HalmosMockVotes votes;
    address owner = address(this);

    string[] opts;

    function setUp() public {
        votes = new HalmosMockVotes();
        voting = new PoolVoting(IERC5805(address(votes)), owner);
        opts.push("A");
        opts.push("B");
        votes.setClock(1000);
    }

    function _sumTally(uint256 id) internal view returns (uint256 sum) {
        uint256[] memory t = voting.tally(id);
        for (uint256 i = 0; i < t.length; i++) {
            sum += t[i];
        }
    }

    /// @notice First vote from `voter` increases the tally sum by exactly
    ///         their weight; nothing else can move it.
    function check_firstVote_movesSumByExactlyWeight(address voter, uint16 option, uint256 weight) public {
        vm.assume(voter != address(0));
        vm.assume(option < opts.length);
        vm.assume(weight > 0 && weight < type(uint128).max);

        uint256 id = voting.propose("p", opts, uint48(block.timestamp + 1), uint48(block.timestamp + 1 + 1 days));
        votes.setPastVotes(voter, voting.tally(id).length == 0 ? 0 : _snapshotOf(id), weight);

        vm.warp(block.timestamp + 1);

        uint256 before = _sumTally(id);
        vm.prank(voter);
        voting.vote(id, option);
        uint256 aft = _sumTally(id);

        assert(aft == before + weight);
    }

    /// @notice A re-vote (same voter, second call) leaves the tally sum
    ///         unchanged: the prior weight is subtracted before the new
    ///         weight is added back.
    function check_revote_conservesSum(address voter, uint16 option1, uint16 option2, uint256 weight) public {
        vm.assume(voter != address(0));
        vm.assume(option1 < opts.length && option2 < opts.length);
        vm.assume(weight > 0 && weight < type(uint128).max);

        uint256 id = voting.propose("p", opts, uint48(block.timestamp + 1), uint48(block.timestamp + 1 + 1 days));
        votes.setPastVotes(voter, _snapshotOf(id), weight);

        vm.warp(block.timestamp + 1);

        vm.prank(voter);
        voting.vote(id, option1);
        uint256 afterFirst = _sumTally(id);

        vm.prank(voter);
        voting.vote(id, option2);
        uint256 afterSecond = _sumTally(id);

        assert(afterSecond == afterFirst);
    }

    /// @notice cancel() never edits any tally entry, before or after a vote
    ///         has been cast.
    function check_cancel_neverModifiesTally(address voter, uint16 option, uint256 weight) public {
        vm.assume(voter != address(0));
        vm.assume(option < opts.length);
        vm.assume(weight > 0 && weight < type(uint128).max);

        uint256 id = voting.propose("p", opts, uint48(block.timestamp + 1), uint48(block.timestamp + 1 + 1 days));
        votes.setPastVotes(voter, _snapshotOf(id), weight);

        vm.warp(block.timestamp + 1);
        vm.prank(voter);
        voting.vote(id, option);

        uint256 before = _sumTally(id);
        voting.cancel(id);
        uint256 aft = _sumTally(id);

        assert(aft == before);
    }

    function _snapshotOf(uint256 id) internal view returns (uint48 snap) {
        (, snap,,,) = voting.proposal(id);
    }
}
