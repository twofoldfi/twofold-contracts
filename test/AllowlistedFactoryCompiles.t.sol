// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Pulls the vendored AllowlistedFactory into forge's compilation graph,
// isolated in its own file so it stays in the default (via_ir=false,
// optimizer_runs=44444444) compilation unit and never mixes with DualPoolHook.
import {Test} from "forge-std/Test.sol";
import {AllowlistedFactory} from "v4-hooks/AllowlistedFactory.sol";

contract AllowlistedFactoryCompilesTest is Test {
    function test_allowlistedFactoryCompiles() public pure {
        assertTrue(true);
    }
}
