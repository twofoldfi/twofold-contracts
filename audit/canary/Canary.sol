// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Deliberately vulnerable throwaway contract used ONLY to prove mythril actually
///         executes symbolic analysis (vs. the three silent-no-op failure modes documented in
///         CLAUDE.md: wrong bytecode kind, incomplete remappings, bare `.sol` with no solc-json).
///         Contains a textbook pay-before-zero reentrancy in `withdraw` and a wide-open `rug()`
///         that drains the whole contract balance to any caller. NEVER deployed; NEVER shipped.
contract Canary {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "insufficient");
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        balances[msg.sender] -= amount;
    }

    function rug() external {
        (bool ok, ) = msg.sender.call{value: address(this).balance}("");
        require(ok, "transfer failed");
    }
}

