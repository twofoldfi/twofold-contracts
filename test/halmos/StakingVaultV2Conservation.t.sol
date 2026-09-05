// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StakingVaultV2} from "../../src/StakingVaultV2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SymStakeV2 is ERC20 {
    constructor() ERC20("Stake", "STK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract SymRewardV2 is ERC20 {
    constructor() ERC20("Reward", "RWD") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// @notice Halmos symbolic properties over StakingVaultV2's streaming reward accounting. The
///         v1 properties (conservation, stake/unstake) carry over unchanged; the two new ones
///         are the reason the contract exists: nothing is claimable at the instant of a notify,
///         and the stream never pays out more than was notified no matter how much time passes.
contract StakingVaultV2ConservationTest is Test {
    StakingVaultV2 sv;
    SymStakeV2 stk;
    SymRewardV2 rwd;
    address alice = address(0x1111);
    address bob = address(0x2222);
    address rewarder = address(0x3333);
    uint256 constant DURATION = 7 days;

    function setUp() public {
        stk = new SymStakeV2();
        rwd = new SymRewardV2();
        sv = new StakingVaultV2(address(this), address(stk), 1 days, DURATION);
        sv.setRewarder(rewarder, true);
    }

    function _stakeAndNotify(uint256 aliceAmount, uint256 rewardAmount) internal {
        stk.mint(alice, aliceAmount);
        rwd.mint(rewarder, rewardAmount);
        vm.prank(alice);
        stk.approve(address(sv), aliceAmount);
        vm.prank(rewarder);
        rwd.approve(address(sv), rewardAmount);
        vm.prank(alice);
        sv.stake(aliceAmount);
        vm.prank(rewarder);
        sv.notifyReward(address(rwd), rewardAmount);
    }

    /// @notice The property v1 could not hold: at the instant of a notify, nothing is claimable.
    ///         This is what stops a staker who arrives one block early from taking the pot.
    function check_nothingIsClaimableAtNotifyInstant(uint256 aliceAmount, uint256 rewardAmount) public {
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e9);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e9);
        _stakeAndNotify(aliceAmount, rewardAmount);
        assert(sv.earned(alice, address(rwd)) == 0);
    }

    /// @notice For ANY elapsed time, a lone staker can never be owed more than was notified.
    function check_singleStakerNeverExceedsNotified(uint256 aliceAmount, uint256 rewardAmount, uint256 elapsed)
        public
    {
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e9);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e9);
        vm.assume(elapsed <= 4 * DURATION);
        _stakeAndNotify(aliceAmount, rewardAmount);
        vm.warp(block.timestamp + elapsed);
        assert(sv.earned(alice, address(rwd)) <= rewardAmount);
    }

    /// @notice Concrete-time specialisations of {check_singleStakerNeverExceedsNotified}. The
    ///         symbolic-`elapsed` version times out (the solver has to reason about
    ///         `rate * elapsed / totalStaked` with all three symbolic at once); fixing `elapsed`
    ///         leaves the floor-division rounding argument - the part that could actually break
    ///         conservation - fully symbolic in the amounts. The continuum between these points
    ///         is covered by `testFuzz_neverPaysMoreThanNotified` in test/StakingVaultV2.t.sol.
    function check_singleStakerAtHalfStream(uint256 aliceAmount, uint256 rewardAmount) public {
        _checkSingleStakerAfter(aliceAmount, rewardAmount, DURATION / 2);
    }

    function check_singleStakerAtPeriodFinish(uint256 aliceAmount, uint256 rewardAmount) public {
        _checkSingleStakerAfter(aliceAmount, rewardAmount, DURATION);
    }

    function check_singleStakerLongAfterPeriodFinish(uint256 aliceAmount, uint256 rewardAmount) public {
        _checkSingleStakerAfter(aliceAmount, rewardAmount, 4 * DURATION);
    }

    function _checkSingleStakerAfter(uint256 aliceAmount, uint256 rewardAmount, uint256 elapsed) internal {
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e9);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e9);
        _stakeAndNotify(aliceAmount, rewardAmount);
        vm.warp(block.timestamp + elapsed);
        assert(sv.earned(alice, address(rwd)) <= rewardAmount);
    }

    /// @notice Two stakers, any elapsed time: the pair can never claim more than was notified.
    function check_rewardConservation(
        uint256 aliceAmount,
        uint256 bobAmount,
        uint256 rewardAmount,
        uint256 elapsed
    ) public {
        vm.assume(aliceAmount > 0 && aliceAmount <= 1e9);
        vm.assume(bobAmount > 0 && bobAmount <= 1e9);
        vm.assume(rewardAmount > 0 && rewardAmount <= 1e9);
        vm.assume(elapsed <= 4 * DURATION);

        stk.mint(alice, aliceAmount);
        stk.mint(bob, bobAmount);
        rwd.mint(rewarder, rewardAmount);
        vm.prank(alice);
        stk.approve(address(sv), aliceAmount);
        vm.prank(bob);
        stk.approve(address(sv), bobAmount);
        vm.prank(rewarder);
        rwd.approve(address(sv), rewardAmount);

        vm.prank(alice);
        sv.stake(aliceAmount);
        vm.prank(bob);
        sv.stake(bobAmount);
        vm.prank(rewarder);
        sv.notifyReward(address(rwd), rewardAmount);

        vm.warp(block.timestamp + elapsed);
        assert(sv.earned(alice, address(rwd)) + sv.earned(bob, address(rwd)) <= rewardAmount);
    }

    /// @notice Unchanged from v1: no amount is created or destroyed by stake -> startUnstake.
    function check_stakeUnstakeConservation(uint256 amount) public {
        amount = bound(amount, 1, 1e30);
        stk.mint(alice, amount);
        vm.prank(alice);
        stk.approve(address(sv), amount);
        vm.prank(alice);
        sv.stake(amount);

        assert(sv.staked(alice) == amount);
        assert(sv.totalStaked() == amount);

        vm.prank(alice);
        sv.startUnstake(amount);

        assert(sv.staked(alice) == 0);
        assert(sv.totalStaked() == 0);
        (uint256 pendingAmount,) = sv.pending(alice);
        assert(pendingAmount == amount);
        assert(stk.balanceOf(address(sv)) == amount);
    }
}
