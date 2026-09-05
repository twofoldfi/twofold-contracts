// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
// Task 6 — harvest. Reuses the MockDualPoolHookV2 / MockERC20V2 from
// test/OperatorControllerV2.t.sol (extended there with configurable
// sharesOf/previewWithdraw and a recording, token-moving removeLiquidity).
//
// Skim-to-shares formula (see OperatorControllerV2.harvest's NatSpec for the
// full derivation and the FINDING-1 fix rationale): `hook.removeLiquidity`
// pays out strictly pro-rata across both currencies, so a combined-value
// formula can pull principal from a leg that didn't gain. Each currency
// independently bounds the shares that may be burned without that currency's
// payout exceeding its own skim value, and the tighter bound wins:
//
//   bound_i    = value_i > 0 ? sharesHeld * skimValue_i / value_i : 0
//   skimShares = min(bound0, bound1)
//
// where skimValue_i = gain_i * skimBps / 10_000, gain_i = max(value_i -
// basis_i, 0). A leg at or below its basis forces skimShares = 0 (clean
// no-op) — the controller only skims when BOTH legs are at or above basis.
//
// Test scenario for test_harvestSkimsOnlyGainShare (chosen so the numbers are
// exact, not just "a mock returns whatever"): symmetric equal-ratio gain on
// both legs so bound0 == bound1 and the min is unambiguous.
//   basis0 = basis1 = 1000, value0 = value1 = 1100, skimBps = 2000 (20%)
//   gain0 = gain1 = 100 -> skimValue0 = skimValue1 = 20
//   sharesHeld = 1100 (chosen 1:1 with value for a clean bound)
//   bound0 = bound1 = 1100 * 20 / 1100 = 20 -> skimShares = 20
//
// Test scenario for test_harvestBothLegsGainExactShares (the reviewer's
// counterexample numbers, both legs gaining at DIFFERENT ratios so the min
// is load-bearing and not just "both bounds happen to be equal"):
//   basis0 = basis1 = 1000, value0 = 1600, value1 = 1200, skimBps = 2000 (20%)
//   gain0 = 600, gain1 = 200 -> skimValue0 = 120, skimValue1 = 40
//   sharesHeld = 3000
//   bound0 = 3000 * 120 / 1600 = 225
//   bound1 = 3000 * 40  / 1200 = 100
//   skimShares = min(225, 100) = 100  (currency1's bound is the binding one)
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {OperatorControllerV2} from "../src/OperatorControllerV2.sol";
import {VaultAllowlist} from "../src/VaultAllowlist.sol";
import {StakingVaultV2} from "../src/StakingVaultV2.sol";
import {MockDualPoolHookV2, MockERC20V2} from "./OperatorControllerV2.t.sol";

contract OperatorControllerHarvestV2Test is Test {
    OperatorControllerV2 internal controller;
    MockDualPoolHookV2 internal mockHook;
    VaultAllowlist internal allowlist;
    StakingVaultV2 internal stakingVault;
    MockERC20V2 internal token0;
    MockERC20V2 internal token1;
    MockERC20V2 internal stakeToken;

    address internal multisig = address(0xA11CE);
    address internal staker = address(0x57A4E4);

    uint16 internal constant SKIM_BPS = 2000; // 20%

    PoolKey internal key;

    function setUp() public {
        MockERC20V2 a = new MockERC20V2();
        MockERC20V2 b = new MockERC20V2();
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        mockHook = new MockDualPoolHookV2(address(this));

        allowlist = new VaultAllowlist(multisig);

        stakeToken = new MockERC20V2();
        stakingVault = new StakingVaultV2(multisig, address(stakeToken), 0, 7 days);

        controller =
            new OperatorControllerV2(multisig, address(mockHook), address(allowlist), address(stakingVault), SKIM_BPS);

        // StakingVaultV2.notifyReward accrues to `unallocated` when totalStaked == 0 (it does not
        // must be a rewarder for notifyReward's role check to pass — both are deployment wiring
        // revert as v1 did), but the harvest tests still stake so the streams credit someone. FINDING 4
        // (deploy-order dependency): harvest() reverts until BOTH of these are true on the real
        // deployment: `stakingVault.setRewarder(controller, true)` has been called by the
        // StakingVaultV2 owner, AND `stakingVault.totalStaked() > 0` (at least one staker has
        // staked). See task-6-report.md for the full note to carry into the deploy script task.
        vm.startPrank(multisig);
        stakingVault.setRewarder(address(controller), true);
        vm.stopPrank();

        stakeToken.mint(staker, 1e18);
        vm.startPrank(staker);
        stakeToken.approve(address(stakingVault), 1e18);
        stakingVault.stake(1e18);
        vm.stopPrank();

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(mockHook))
        });

        // Fund the mock hook so its removeLiquidity transfers are backed by real balance.
        token0.mint(address(mockHook), 1_000_000e18);
        token1.mint(address(mockHook), 1_000_000e18);
    }

    function _setBasisScenario(uint256 basis0, uint256 basis1, uint256 shares) internal {
        mockHook.setSharesOf(shares);
        mockHook.setPreviewWithdraw(basis0, basis1);
        vm.prank(multisig);
        controller.recordBasis(key);
    }

    // ── Core skim math ──────────────────────────────────────────────────────

    function test_harvestSkimsOnlyGainShare() public {
        _setBasisScenario(1000, 1000, 1100);

        mockHook.setPreviewWithdraw(1100, 1100);
        mockHook.setRemoveLiquidityReturn(20, 20);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);

        assertEq(mockHook.removeLiquidityCalls(), 1);
        assertEq(mockHook.lastRemoveShares(), 20);

        // StakingVaultV2 received the removeLiquidity proceeds via notifyReward, as a stream:
        // nothing is credited at the instant of the notify, the rate carries the whole amount.
        (uint256 rate0,,, uint256 acc0,) = stakingVault.streams(address(token0));
        (uint256 rate1,,, uint256 acc1,) = stakingVault.streams(address(token1));
        assertEq(acc0, 0);
        assertEq(acc1, 0);
        assertEq(rate0, uint256(20) * 1e27 / uint256(7 days));
        assertEq(rate1, uint256(20) * 1e27 / uint256(7 days));
        assertEq(token0.balanceOf(address(stakingVault)), 20);
        assertEq(token1.balanceOf(address(stakingVault)), 20);
    }

    /// @dev The reviewer's counterexample, with asymmetric per-leg gain ratios so the two bounds
    ///      genuinely differ (bound0 = 225, bound1 = 100) and the `min` is load-bearing — this is
    ///      the exact-value regression test for FINDING 1 (the old combined-value formula would
    ///      have computed 3000 * (120 + 40) / (1600 + 1200) = 171, which is neither bound and
    ///      would have overpaid currency1 relative to its own skim value). Also the test that
    ///      pins down and kills the previously-surviving "drop skimValue1 from the formula"
    ///      mutation (see task-6-report.md's fix-report mutation table).
    function test_harvestBothLegsGainExactShares() public {
        _setBasisScenario(1000, 1000, 3000);

        mockHook.setPreviewWithdraw(1600, 1200);
        mockHook.setRemoveLiquidityReturn(120, 40);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);

        assertEq(mockHook.removeLiquidityCalls(), 1);
        assertEq(mockHook.lastRemoveShares(), 100, "skimShares must equal min(bound0=225, bound1=100)");
    }

    /// @dev Both currencies gain, so both notifyReward legs must fire (not just currency0, which
    ///      every other scenario in this file exercises alone).
    function test_harvestForwardsBothCurrencies() public {
        _setBasisScenario(1000, 1000, 2000);
        mockHook.setPreviewWithdraw(1100, 1200);
        mockHook.setRemoveLiquidityReturn(20, 40);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);

        assertEq(mockHook.removeLiquidityCalls(), 1);
        assertEq(token0.balanceOf(address(stakingVault)), 20);
        assertEq(token1.balanceOf(address(stakingVault)), 40);
        (uint256 r0,,,,) = stakingVault.streams(address(token0));
        (uint256 r1,,,,) = stakingVault.streams(address(token1));
        assertGt(r0, 0);
        assertGt(r1, 0);
    }

    /// @dev Positive gain on both legs, but small enough that `skimValue_i` itself floors to 0
    ///      at the bps step (before any shares conversion) — must still no-op cleanly rather
    ///      than call `removeLiquidity(0, ...)`.
    function test_harvestSkimsRoundingToZeroSharesNoOp() public {
        _setBasisScenario(1000, 1000, 2002);
        // gain0 = gain1 = 1 -> skimValue_i = 1 * 2000 / 10_000 = 0 (floors) for BOTH legs.
        mockHook.setPreviewWithdraw(1001, 1001);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 0);
    }

    // ── No-gain / mixed gain-loss no-op ─────────────────────────────────────

    function test_harvestNoGainNoOp() public {
        _setBasisScenario(1000, 1000, 2000);

        // value == basis: no gain.
        mockHook.setPreviewWithdraw(1000, 1000);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 0);

        // value < basis: still no gain, still no-op, still no revert.
        mockHook.setPreviewWithdraw(900, 1000);
        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 0);
    }

    /// @dev Zero basis and zero current value (e.g. no shares held yet) must still no-op cleanly
    ///      rather than revert. This is the case where the no-gain short-circuit is load-bearing:
    ///      without it, dividing to compute a bound would divide by zero.
    function test_harvestNoGainNoOpAtZeroValue() public {
        _setBasisScenario(0, 0, 0);
        mockHook.setPreviewWithdraw(0, 0);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 0);
    }

    /// @dev FINDING 1's core regression test: one leg gained, the other sits below its basis
    ///      (a real loss, not just flat). `hook.removeLiquidity` pays out pro-rata across BOTH
    ///      currencies, so skimming currency0's gain here would have forwarded currency1
    ///      PRINCIPAL to stakers under the old combined-value formula. Per the ruling, the
    ///      per-leg-bounded minimum forces `skimShares = 0` whenever either leg's skim value is
    ///      0 — harvest waits for both legs to recover instead. Basis must also stay untouched
    ///      (no silent write on the no-op path).
    function test_harvestMixedGainLossNoOp() public {
        _setBasisScenario(1000, 1000, 2000);
        // currency0 gained; currency1 dropped below its basis (a real loss).
        mockHook.setPreviewWithdraw(1100, 900);

        (uint256 basisBefore0, uint256 basisBefore1) = controller.basis(key.toId());

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);

        assertEq(mockHook.removeLiquidityCalls(), 0, "must not pull principal from the losing leg");
        (uint256 basisAfter0, uint256 basisAfter1) = controller.basis(key.toId());
        assertEq(basisAfter0, basisBefore0, "basis0 must be unchanged on no-op");
        assertEq(basisAfter1, basisBefore1, "basis1 must be unchanged on no-op");
    }

    // ── Basis updates to post-harvest value ─────────────────────────────────

    function test_harvestUpdatesBasis() public {
        _setBasisScenario(1000, 1000, 1100);

        mockHook.setPreviewWithdraw(1100, 1100);
        mockHook.setRemoveLiquidityReturn(20, 20);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 1);

        (uint256 b0, uint256 b1) = controller.basis(key.toId());
        // Basis is re-read from the hook post-harvest; the mock's previewWithdraw is static
        // (unchanged by the removeLiquidity call), so the new basis equals the same (1100, 1100)
        // the hook currently reports — meaning an immediate second harvest sees zero gain.
        assertEq(b0, 1100);
        assertEq(b1, 1100);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 1, "second immediate harvest must be a no-op");
    }

    // ── Auth ─────────────────────────────────────────────────────────────────

    function test_harvestOnlyOwner() public {
        _setBasisScenario(1000, 1000, 1100);
        mockHook.setPreviewWithdraw(1100, 1100);
        mockHook.setRemoveLiquidityReturn(20, 20);

        address stranger = address(0xC0FFEE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        controller.harvest(key, 0, 0, block.timestamp);
    }

    // ── Slippage / deadline pass-through ────────────────────────────────────

    function test_slippageParamsForwarded() public {
        _setBasisScenario(1000, 1000, 1100);
        mockHook.setPreviewWithdraw(1100, 1100);
        mockHook.setRemoveLiquidityReturn(20, 20);

        uint256 minAmount0 = 17;
        uint256 minAmount1 = 3;
        uint256 deadline = block.timestamp + 3600;

        vm.prank(multisig);
        controller.harvest(key, minAmount0, minAmount1, deadline);

        assertEq(mockHook.lastRemoveMinAmount0(), minAmount0);
        assertEq(mockHook.lastRemoveMinAmount1(), minAmount1);
        assertEq(mockHook.lastRemoveDeadline(), deadline);
    }
}
