// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {TwoStakingUSDG} from "../src/TwoStakingUSDG.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockTWO is ERC20 {
    constructor() ERC20("MockTWO", "TWO") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract MockUSDG is ERC20 {
    constructor() ERC20("MockUSDG", "USDG") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract TwoStakingUSDGTest is Test {
    TwoStakingUSDG ts;
    MockTWO two;
    MockUSDG usdg;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address funder = makeAddr("funder");
    uint256 constant COOLDOWN = 7 days;
    uint256 constant DURATION = 7 days;
    uint256 constant CAP = 1_000_000e18;

    function setUp() public {
        two = new MockTWO();
        usdg = new MockUSDG();
        ts = new TwoStakingUSDG(owner, address(two), address(usdg), COOLDOWN, DURATION, CAP);
        vm.prank(owner);
        ts.setRewarder(funder, true);
        two.mint(alice, 1_000_000e18);
        two.mint(bob, 1_000_000e18);
        usdg.mint(funder, 10_000_000e6);
        vm.prank(alice); two.approve(address(ts), type(uint256).max);
        vm.prank(bob); two.approve(address(ts), type(uint256).max);
        vm.prank(funder); usdg.approve(address(ts), type(uint256).max);
    }

    function _fund(uint256 amt) internal {
        vm.prank(funder);
        ts.notifyReward(amt);
    }

    function _stake(address who, uint256 amt) internal {
        vm.prank(who);
        ts.stake(amt);
    }

    // ---- drip ----

    function test_nothingPaidInstantly() public {
        _stake(alice, 100e18);
        _fund(700e6);
        assertEq(ts.earned(alice), 0);
    }

    function test_accrualIsProportionalToTime() public {
        _stake(alice, 100e18);
        _fund(700e6);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(ts.earned(alice), 100e6, 1e12);
        vm.warp(block.timestamp + 6 days);
        assertApproxEqRel(ts.earned(alice), 700e6, 1e12);
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(ts.earned(alice), 700e6, 1e12);
        assertLe(ts.earned(alice), 700e6);
    }

    function test_lateStakerCannotCaptureEarlierDrip() public {
        _stake(alice, 100e18);
        _fund(700e6);
        vm.warp(block.timestamp + 3 days);
        _stake(bob, 100e18);
        assertEq(ts.earned(bob), 0);
        vm.warp(block.timestamp + 4 days);
        assertApproxEqRel(ts.earned(alice), 500e6, 1e12);
        assertApproxEqRel(ts.earned(bob), 200e6, 1e12);
    }

    function test_fundWithNobodyStakedIsHeldThenStreamed() public {
        _fund(700e6);
        vm.warp(block.timestamp + 10 days);
        (,,,, uint256 unalloc) = ts.stream();
        assertEq(unalloc, 0, "nothing accrues into unallocated until a stream tick");
        _stake(alice, 100e18);
        (,,,, unalloc) = ts.stream();
        assertApproxEqRel(unalloc, 700e6 * 1e27, 1e12, "the untouched stream is parked");
        _fund(700e6);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(ts.earned(alice), 1400e6, 1e12);
    }

    function test_midStreamFundFoldsRemainder() public {
        _stake(alice, 100e18);
        _fund(700e6);
        vm.warp(block.timestamp + 4 days);
        _fund(700e6);
        (uint256 rate, uint256 finish,,,) = ts.stream();
        assertEq(finish, block.timestamp + 7 days);
        assertApproxEqRel(rate * 7 days, 1000e6 * 1e27, 1e12);
        vm.warp(block.timestamp + 7 days);
        assertApproxEqRel(ts.earned(alice), 1400e6, 1e12);
    }

    function test_claimRewardsPaysAndZeroes() public {
        _stake(alice, 100e18);
        _fund(700e6);
        vm.warp(block.timestamp + 1 days);
        uint256 e = ts.earned(alice);
        vm.prank(alice);
        ts.claimRewards();
        assertEq(usdg.balanceOf(alice), e);
        assertEq(ts.earned(alice), 0);
    }

    function test_claimRewardsWithNothingIsNoop() public {
        vm.prank(alice);
        ts.claimRewards();
        assertEq(usdg.balanceOf(alice), 0);
    }

    function testFuzz_neverPaysMoreThanNotified(uint256 a, uint256 b, uint256 r, uint256 t) public {
        a = bound(a, 1, 500_000e18);
        b = bound(b, 1, 500_000e18);
        r = bound(r, 1, 1_000_000e6);
        t = bound(t, 0, 60 days);
        _stake(alice, a);
        _stake(bob, b);
        _fund(r);
        vm.warp(block.timestamp + t);
        assertLe(ts.earned(alice) + ts.earned(bob), r);
    }

    // ---- exit cooldown ----

    function test_startUnstakeStopsEarningImmediately() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        _fund(700e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        ts.startUnstake(100e18);
        uint256 frozen = ts.earned(alice);
        vm.warp(block.timestamp + 6 days);
        assertEq(ts.earned(alice), frozen);
        assertApproxEqRel(ts.earned(bob), 50e6 + 600e6, 1e12);
    }

    function test_claimUnstakedBeforeUnlockReverts() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        ts.startUnstake(100e18);
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(alice);
        vm.expectRevert(TwoStakingUSDG.CooldownActive.selector);
        ts.claimUnstaked();
    }

    function test_claimUnstakedAfterUnlockPays() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        ts.startUnstake(40e18);
        vm.warp(block.timestamp + 7 days);
        uint256 before = two.balanceOf(alice);
        vm.prank(alice);
        ts.claimUnstaked();
        assertEq(two.balanceOf(alice) - before, 40e18);
        assertEq(ts.staked(alice), 60e18);
        (uint256 pAmt, uint256 pUnlock) = ts.pending(alice);
        assertEq(pAmt, 0);
        assertEq(pUnlock, 0);
    }

    function test_claimUnstakedWithNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(TwoStakingUSDG.NothingToClaim.selector);
        ts.claimUnstaked();
    }

    function test_secondUnstakeMergesAndResetsClock() public {
        _stake(alice, 101e18);
        vm.prank(alice);
        ts.startUnstake(1e18);
        uint256 firstUnlock = block.timestamp + 7 days;
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        ts.startUnstake(100e18);
        (uint256 pAmt, uint256 pUnlock) = ts.pending(alice);
        assertEq(pAmt, 101e18);
        assertEq(pUnlock, block.timestamp + ts.cooldown());
        assertGt(pUnlock, firstUnlock);
        vm.warp(firstUnlock);
        vm.prank(alice);
        vm.expectRevert(TwoStakingUSDG.CooldownActive.selector);
        ts.claimUnstaked();
        vm.warp(pUnlock);
        vm.prank(alice);
        ts.claimUnstaked();
        assertEq(ts.staked(alice), 0);
    }

    function test_unstakeMoreThanStakedReverts() public {
        _stake(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        ts.startUnstake(11e18);
    }

    // ---- cap and pause ----

    function test_capBlocksStakeAndSetCapReopens() public {
        _stake(alice, CAP);
        assertEq(ts.stakeRoom(), 0);
        vm.prank(bob);
        vm.expectRevert(TwoStakingUSDG.CapExceeded.selector);
        ts.stake(1);
        vm.prank(owner);
        ts.setCap(CAP + 5e18);
        assertEq(ts.stakeRoom(), 5e18);
        _stake(bob, 5e18);
        vm.prank(bob);
        vm.expectRevert(TwoStakingUSDG.CapExceeded.selector);
        ts.stake(1);
    }

    function test_loweringCapBelowTotalForcesNobodyOut() public {
        _stake(alice, 100e18);
        vm.prank(owner);
        ts.setCap(10e18);
        assertEq(ts.stakeRoom(), 0);
        assertEq(ts.staked(alice), 100e18);
        _fund(700e6);
        vm.warp(block.timestamp + 1 days);
        assertGt(ts.earned(alice), 0);
        vm.prank(alice);
        ts.startUnstake(100e18);
    }

    function test_pauseBlocksStakeOnly() public {
        _stake(alice, 100e18);
        _fund(700e6);
        vm.prank(owner);
        ts.setStakingPaused(true);
        vm.prank(bob);
        vm.expectRevert(TwoStakingUSDG.StakingPaused.selector);
        ts.stake(1e18);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        ts.claimRewards();
        assertGt(usdg.balanceOf(alice), 0);
        vm.prank(alice);
        ts.startUnstake(100e18);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        ts.claimUnstaked();
        vm.prank(owner);
        ts.setStakingPaused(false);
        _stake(bob, 1e18);
    }

    function test_onlyOwnerSetsCapPauseRewarder() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ts.setCap(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ts.setStakingPaused(true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ts.setRewarder(alice, true);
        vm.stopPrank();
    }

    // ---- funding ----

    function test_nonRewarderCannotFund() public {
        usdg.mint(alice, 1e6);
        vm.startPrank(alice);
        usdg.approve(address(ts), 1e6);
        vm.expectRevert(TwoStakingUSDG.NotRewarder.selector);
        ts.notifyReward(1e6);
        vm.stopPrank();
    }

    function test_zeroAmountsRevert() public {
        vm.prank(alice);
        vm.expectRevert(TwoStakingUSDG.ZeroAmount.selector);
        ts.stake(0);
        vm.prank(alice);
        vm.expectRevert(TwoStakingUSDG.ZeroAmount.selector);
        ts.startUnstake(0);
        vm.prank(funder);
        vm.expectRevert(TwoStakingUSDG.ZeroAmount.selector);
        ts.notifyReward(0);
    }

    function test_constructorRejectsZeroDuration() public {
        vm.expectRevert(TwoStakingUSDG.ZeroDuration.selector);
        new TwoStakingUSDG(owner, address(two), address(usdg), COOLDOWN, 0, CAP);
    }

    // ---- ownership and no-rescue ----

    function test_ownershipIsTwoStep() public {
        vm.prank(owner);
        ts.transferOwnership(bob);
        assertEq(ts.owner(), owner);
        assertEq(ts.pendingOwner(), bob);
        vm.prank(bob);
        ts.acceptOwnership();
        assertEq(ts.owner(), bob);
    }

    function test_ownerHasNoPathToFunds() public {
        _stake(alice, 100e18);
        _fund(700e6);
        bytes4[5] memory sels = [
            bytes4(keccak256("sweep(address,uint256)")),
            bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("recoverERC20(address,uint256)")),
            bytes4(keccak256("emergencyWithdraw()"))
        ];
        for (uint256 i = 0; i < sels.length; i++) {
            vm.prank(owner);
            (bool ok,) = address(ts).call(abi.encodeWithSelector(sels[i], address(usdg), 1));
            assertFalse(ok);
        }
        assertEq(usdg.balanceOf(address(ts)), 700e6);
        assertEq(two.balanceOf(address(ts)), 100e18);
    }

    function test_solvencyAfterMixedActivity() public {
        _stake(alice, 300e18);
        _fund(1000e6);
        vm.warp(block.timestamp + 2 days);
        _stake(bob, 100e18);
        vm.prank(alice);
        ts.claimRewards();
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        ts.startUnstake(150e18);
        _fund(500e6);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice); ts.claimRewards();
        vm.prank(bob); ts.claimRewards();
        vm.prank(alice); ts.claimUnstaked();
        assertLe(usdg.balanceOf(alice) + usdg.balanceOf(bob), 1500e6);
        assertEq(two.balanceOf(address(ts)), ts.totalStaked());
    }

    // ---- hardening (2026-09-03) ----

    function test_constructorRejectsZeroStakeToken() public {
        vm.expectRevert(TwoStakingUSDG.ZeroAddress.selector);
        new TwoStakingUSDG(owner, address(0), address(usdg), COOLDOWN, DURATION, CAP);
    }

    function test_constructorRejectsZeroRewardToken() public {
        vm.expectRevert(TwoStakingUSDG.ZeroAddress.selector);
        new TwoStakingUSDG(owner, address(two), address(0), COOLDOWN, DURATION, CAP);
    }

    function test_renounceOwnershipRevertsForOwner() public {
        vm.prank(owner);
        vm.expectRevert(TwoStakingUSDG.RenounceDisabled.selector);
        ts.renounceOwnership();
        assertEq(ts.owner(), owner);
    }

    function test_renounceOwnershipRevertsForStranger() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        ts.renounceOwnership();
        assertEq(ts.owner(), owner);
    }

    function test_unstakeStartedEmitsTheDelta() public {
        _stake(alice, 101e18);
        vm.prank(alice);
        ts.startUnstake(1e18);
        vm.expectEmit(true, false, false, true, address(ts));
        emit TwoStakingUSDG.UnstakeStarted(alice, 100e18, block.timestamp + 7 days);
        vm.prank(alice);
        ts.startUnstake(100e18);
        (uint256 pAmt,) = ts.pending(alice);
        assertEq(pAmt, 101e18);
    }

    function test_setRewarderCanBeRevoked() public {
        _fund(700e6);
        vm.prank(owner);
        ts.setRewarder(funder, false);
        assertFalse(ts.rewarder(funder));
        vm.prank(funder);
        vm.expectRevert(TwoStakingUSDG.NotRewarder.selector);
        ts.notifyReward(1e6);
        vm.prank(owner);
        ts.setRewarder(funder, true);
        _fund(1e6);
    }

    function test_stakeConservationWithPendingQueue() public {
        _stake(alice, 300e18);
        _stake(bob, 100e18);
        vm.prank(alice);
        ts.startUnstake(120e18);
        (uint256 pAmt,) = ts.pending(alice);
        assertEq(two.balanceOf(address(ts)), ts.totalStaked() + pAmt);
        assertEq(ts.totalStaked(), 280e18);
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        ts.claimUnstaked();
        assertEq(two.balanceOf(address(ts)), ts.totalStaked());
    }
}
