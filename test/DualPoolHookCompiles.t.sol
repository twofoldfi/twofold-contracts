// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Pulls the vendored DualPoolHook into forge's compilation graph, isolated in
// its own file so it stays in the src/alf/** restricted (via_ir=true,
// optimizer_runs=200) compilation unit and never mixes with AllowlistedFactory.
import {Test} from "forge-std/Test.sol";
import {DualPoolHook} from "v4-hooks/alf/DualPoolHook.sol";

contract DualPoolHookCompilesTest is Test {
    function test_dualPoolHookCompiles() public pure {
        assertTrue(true);
    }
}
