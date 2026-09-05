// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  PoolVoting                                                           ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";

contract PoolVoting is Ownable2Step {
    error BadOptions();
    error BadWindow();
    error NoProposal();
    error NotOpen();
    error Canceled();
    error BadOption();
    error NoWeight();

    struct Proposal {
        string description;
        string[] options;
        uint256[] tally;
        uint48 snapshot;
        uint48 start;
        uint48 end;
        bool canceled;
    }

    struct Receipt {
        bool voted;
        uint16 option;
        uint256 weight;
    }

    event ProposalCreated(
        uint256 indexed id, uint48 snapshot, uint48 start, uint48 end, string description, string[] options
    );
    event VoteCast(uint256 indexed id, address indexed voter, uint16 option, uint256 weight);
    event ProposalCanceled(uint256 indexed id);

    IERC5805 public immutable token;
    uint48 public constant MIN_WINDOW = 1 days;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) internal _proposals;
    mapping(uint256 => mapping(address => Receipt)) public receipts;

    constructor(IERC5805 votesToken, address initialOwner) Ownable(initialOwner) {
        token = votesToken;
    }

    function propose(string calldata description, string[] calldata options_, uint48 start, uint48 end)
        external
        onlyOwner
        returns (uint256 id)
    {
        if (options_.length < 2 || options_.length > 16) revert BadOptions();
        if (start < block.timestamp || end <= start || end - start < MIN_WINDOW) revert BadWindow();
        id = proposalCount++;
        Proposal storage p = _proposals[id];
        p.description = description;
        p.options = options_;
        p.tally = new uint256[](options_.length);
        p.snapshot = token.clock() - 1;
        p.start = start;
        p.end = end;
        emit ProposalCreated(id, p.snapshot, start, end, description, options_);
    }

    function vote(uint256 id, uint16 option) external {
        if (id >= proposalCount) revert NoProposal();
        Proposal storage p = _proposals[id];
        if (p.canceled) revert Canceled();
        if (block.timestamp < p.start || block.timestamp > p.end) revert NotOpen();
        if (option >= p.options.length) revert BadOption();
        uint256 weight = token.getPastVotes(msg.sender, p.snapshot);
        if (weight == 0) revert NoWeight();
        Receipt storage r = receipts[id][msg.sender];
        if (r.voted) {
            p.tally[r.option] -= r.weight;
        }
        r.voted = true;
        r.option = option;
        r.weight = weight;
        p.tally[option] += weight;
        emit VoteCast(id, msg.sender, option, weight);
    }

    function cancel(uint256 id) external onlyOwner {
        if (id >= proposalCount) revert NoProposal();
        Proposal storage p = _proposals[id];
        if (block.timestamp > p.end) revert NotOpen();
        if (p.canceled) revert Canceled();
        p.canceled = true;
        emit ProposalCanceled(id);
    }

    function proposal(uint256 id)
        external
        view
        returns (string memory description, uint48 snapshot, uint48 start, uint48 end, bool canceled)
    {
        Proposal storage p = _proposals[id];
        return (p.description, p.snapshot, p.start, p.end, p.canceled);
    }

    function options(uint256 id) external view returns (string[] memory) {
        return _proposals[id].options;
    }

    function tally(uint256 id) external view returns (uint256[] memory) {
        return _proposals[id].tally;
    }
}
