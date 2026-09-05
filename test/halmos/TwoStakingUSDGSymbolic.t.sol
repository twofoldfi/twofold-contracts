// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwoStakingUSDG} from "../../src/TwoStakingUSDG.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SymStake is ERC20 {
    constructor() ERC20("Stake", "STK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract SymReward is ERC20 {
    constructor() ERC20("Reward", "RWD") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @notice Halmos properties over TwoStakingUSDG: the StakingVaultV2 stream properties carried over,
///         plus the three things this contract adds: the cap is a hard ceiling on totalStaked,
///         merge-and-reset never shortens an unlock, and the two token balances are always
///         covered by the ledgers.
contract TwoStakingUSDGSymbolicTest is Test {
    TwoStakingUSDG ts;
    SymStake stk;
    SymReward rwd;
    address alice = address(0x1111);
    address bob = address(0x2222);
    address funder = address(0x3333);
    uint256 constant DURATION = 7 days;
    uint256 constant CAP = 1e12;

    function setUp() public {
        stk = new SymStake();
        rwd = new SymReward();
        ts = new TwoStakingUSDG(address(this), address(stk), address(rwd), 7 days, DURATION, CAP);
        ts.setRewarder(funder, true);
    }

    function _stakeAndFund(uint256 aliceAmount, uint256 rewardAmount) internal {
        stk.mint(alice, aliceAmount);
        rwd.mint(funder, rewardAmount);
        vm.prank(alice);
        stk.approve(address(ts), aliceAmount);
        vm.prank(funder);
        rwd.approve(address(ts), rewardAmount);
        vm.prank(alice);
        ts.stake(aliceAmount);
        vm.prank(funder);
        ts.notifyReward(rewardAmount);
    }

    function check_nothingIsClaimableAtNotifyInstant(uint256 aliceAmount, uint256 rewardAmount) public {
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e9);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e9);
        _stakeAndFund(aliceAmount, rewardAmount);
        assert(ts.earned(alice) == 0);
    }

    function check_singleStakerAtHalfStream(uint256 a, uint256 r) public { _after(a, r, DURATION / 2); }
    function check_singleStakerAtPeriodFinish(uint256 a, uint256 r) public { _after(a, r, DURATION); }
    function check_singleStakerLongAfter(uint256 a, uint256 r) public { _after(a, r, 4 * DURATION); }

    function _after(uint256 aliceAmount, uint256 rewardAmount, uint256 elapsed) internal {
        // Narrowed from 1e9 to 1e6: at 1e9 the solver timed out at 60s on all three
        // concrete-elapsed specializations (see audit/halmos-twostaking.log). Continuum coverage
        // beyond this bound is carried by testFuzz_neverPaysMoreThanNotified in TwoStakingUSDG.t.sol.
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e6);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e6);
        _stakeAndFund(aliceAmount, rewardAmount);
        vm.warp(block.timestamp + elapsed);
        assert(ts.earned(alice) <= rewardAmount);
    }

    /// @notice The cap is a hard ceiling: no stake succeeds that takes totalStaked above it.
    function check_capIsHardCeiling(uint256 first, uint256 second) public {
        vm.assume(first > 0 && first <= CAP);
        vm.assume(second > 0 && second <= 2 * CAP);
        stk.mint(alice, first + second);
        vm.prank(alice);
        stk.approve(address(ts), first + second);
        vm.prank(alice);
        ts.stake(first);
        vm.prank(alice);
        (bool ok,) = address(ts).call(abi.encodeWithSelector(TwoStakingUSDG.stake.selector, second));
        if (ok) assert(first + second <= CAP);
        else assert(first + second > CAP);
        assert(ts.totalStaked() <= CAP);
    }

    /// @notice Merge-and-reset: a second startUnstake never moves the unlock earlier, and the
    ///         queued amount is the exact sum.
    function check_unlockNeverDecreases(uint256 amount, uint256 a1, uint256 a2, uint256 gap) public {
        vm.assume(amount > 0 && amount <= 1e12);
        vm.assume(a1 > 0 && a2 > 0 && a1 + a2 <= amount);
        vm.assume(gap <= 30 days);
        stk.mint(alice, amount);
        vm.prank(alice);
        stk.approve(address(ts), amount);
        vm.prank(alice);
        ts.stake(amount);
        vm.prank(alice);
        ts.startUnstake(a1);
        (, uint256 u1) = ts.pending(alice);
        vm.warp(block.timestamp + gap);
        vm.prank(alice);
        ts.startUnstake(a2);
        (uint256 p2, uint256 u2) = ts.pending(alice);
        assert(u2 >= u1);
        assert(u2 == block.timestamp + 7 days);
        assert(p2 == a1 + a2);
        assert(ts.staked(alice) == amount - a1 - a2);
    }

    /// @notice Stake conservation: the stake-token balance equals totalStaked plus every pending queue.
    function check_stakeConservation(uint256 amount, uint256 exit) public {
        vm.assume(amount > 0 && amount <= 1e12);
        vm.assume(exit > 0 && exit <= amount);
        stk.mint(alice, amount);
        vm.prank(alice);
        stk.approve(address(ts), amount);
        vm.prank(alice);
        ts.stake(amount);
        vm.prank(alice);
        ts.startUnstake(exit);
        (uint256 p,) = ts.pending(alice);
        assert(stk.balanceOf(address(ts)) == ts.totalStaked() + p);
        assert(ts.totalStaked() == amount - exit);
    }

    /// @notice Two stakers, fixed elapsed: the pair can never claim more than was funded.
    function check_rewardConservationTwoStakers(uint256 aliceAmount, uint256 bobAmount, uint256 rewardAmount) public {
        // Narrowed from 1e9 to 1e6: at 1e9 the solver timed out at 60s (see
        // audit/halmos-twostaking.log). Continuum coverage beyond this bound is carried by
        // testFuzz_neverPaysMoreThanNotified in TwoStakingUSDG.t.sol.
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e6);
        vm.assume(bobAmount > 0 && bobAmount <= 1e6);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e6);
        stk.mint(alice, aliceAmount);
        stk.mint(bob, bobAmount);
        rwd.mint(funder, rewardAmount);
        vm.prank(alice); stk.approve(address(ts), aliceAmount);
        vm.prank(bob); stk.approve(address(ts), bobAmount);
        vm.prank(funder); rwd.approve(address(ts), rewardAmount);
        vm.prank(alice); ts.stake(aliceAmount);
        vm.prank(bob); ts.stake(bobAmount);
        vm.prank(funder); ts.notifyReward(rewardAmount);
        vm.warp(block.timestamp + DURATION);
        assert(ts.earned(alice) + ts.earned(bob) <= rewardAmount);
    }
}
