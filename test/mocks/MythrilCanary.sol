// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Deliberately broken contract used ONLY to prove mythril actually executed. It has a
///         textbook reentrancy (pays before zeroing) and an unauthenticated rug(). If mythril
///         reports this clean, every other clean result from that session is void
///         (CLAUDE.md, "MYTHRIL SILENTLY ANALYSES NOTHING AND REPORTS CLEAN").
contract MythrilCanary {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 amount = balances[msg.sender];
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
        balances[msg.sender] = 0;
    }

    function rug(address payable to) external {
        to.transfer(address(this).balance);
    }
}
