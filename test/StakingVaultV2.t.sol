// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StakingVaultV2} from "../src/StakingVaultV2.sol";
import {TwofoldToken} from "../src/TwofoldToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSD is ERC20 {
    constructor() ERC20("MockUSD", "MUSD") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract StakingVaultV2Test is Test {
    StakingVaultV2 sv;
    TwofoldToken fold;
    MockUSD usd;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address controller = makeAddr("controller");
    uint256 constant COOLDOWN = 1 days;
    uint256 constant DURATION = 7 days;

    address[] toks;

    function setUp() public {
        fold = new TwofoldToken(address(this));
        usd = new MockUSD();
        sv = new StakingVaultV2(owner, address(fold), COOLDOWN, DURATION);
        vm.prank(owner);
        sv.setRewarder(controller, true);
        fold.transfer(alice, 1000e18);
        fold.transfer(bob, 1000e18);
        fold.transfer(controller, 1000e18);
        usd.mint(controller, 1_000_000e6);
        vm.prank(alice); fold.approve(address(sv), type(uint256).max);
        vm.prank(bob); fold.approve(address(sv), type(uint256).max);
        vm.prank(controller); fold.approve(address(sv), type(uint256).max);
        vm.prank(controller); usd.approve(address(sv), type(uint256).max);
        toks.push(address(usd));
    }

    function _notify(uint256 amt) internal {
        vm.prank(controller);
        sv.notifyReward(address(usd), amt);
    }

    function test_nothingPaidInstantly() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        assertEq(sv.earned(alice, address(usd)), 0, "instant credit must be zero");
    }

    function test_accrualIsProportionalToTime() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(sv.earned(alice, address(usd)), 100e6, 1e12);
        vm.warp(block.timestamp + 6 days);
        assertApproxEqRel(sv.earned(alice, address(usd)), 700e6, 1e12);
    }

    function test_streamStopsAtPeriodFinish() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + 30 days);
        assertApproxEqRel(sv.earned(alice, address(usd)), 700e6, 1e12);
    }

    function test_lateStakerCannotCaptureTheStream() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + DURATION - 1);
        vm.prank(bob); sv.stake(100e18);
        vm.warp(block.timestamp + 1);
        uint256 bobEarned = sv.earned(bob, address(usd));
        assertLt(bobEarned, 1e6, "one second of stream only");
        assertApproxEqRel(sv.earned(alice, address(usd)) + bobEarned, 700e6, 1e12);
    }

    function test_midPeriodNotifyFoldsLeftoverIn() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + 3 days);
        _notify(300e6);
        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(sv.earned(alice, address(usd)), 1000e6, 1e12);
    }

    function test_claimDuringStreamThenContinueAccruing() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice); sv.claimRewards(toks);
        assertApproxEqRel(usd.balanceOf(alice), 100e6, 1e12);
        assertEq(sv.earned(alice, address(usd)), 0);
        vm.warp(block.timestamp + 6 days);
        assertApproxEqRel(sv.earned(alice, address(usd)), 600e6, 1e12);
    }

    function test_twoStakersSplitByStakeAndTime() public {
        vm.prank(alice); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + 3500 days);
        vm.prank(bob); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(sv.earned(alice, address(usd)), 1050e6, 1e12);
        assertApproxEqRel(sv.earned(bob, address(usd)), 350e6, 1e12);
    }

    function test_notifyWithNobodyStakedIsHeldNotLost() public {
        _notify(700e6);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice); sv.stake(100e18);
        vm.warp(block.timestamp + 30 days);
        _notify(300e6);
        vm.warp(block.timestamp + DURATION);
        assertApproxEqRel(sv.earned(alice, address(usd)), 1000e6, 1e12);
    }

    function test_unstakingStopsAccrual() public {
        vm.prank(alice); sv.stake(100e18);
        vm.prank(bob); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice); sv.startUnstake(100e18);
        vm.warp(block.timestamp + 6 days);
        assertApproxEqRel(sv.earned(alice, address(usd)), 50e6, 1e12);
        assertApproxEqRel(sv.earned(bob, address(usd)), 650e6, 1e12);
    }

    function test_stakeTokenRewardsDoNotTouchPrincipal() public {
        vm.prank(alice); sv.stake(100e18);
        vm.prank(controller); sv.notifyReward(address(fold), 700e18);
        vm.warp(block.timestamp + DURATION);
        address[] memory t = new address[](1);
        t[0] = address(fold);
        vm.prank(alice); sv.claimRewards(t);
        assertApproxEqRel(fold.balanceOf(alice), 900e18 + 700e18, 1e12);
        assertEq(sv.staked(alice), 100e18);
        vm.prank(alice); sv.startUnstake(100e18);
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice); sv.claimUnstaked();
        assertApproxEqRel(fold.balanceOf(alice), 1700e18, 1e12);
    }

    function test_unstakeCooldownEnforced() public {
        vm.prank(alice); sv.stake(100e18);
        vm.prank(alice); sv.startUnstake(100e18);
        vm.prank(alice);
        vm.expectRevert(StakingVaultV2.CooldownActive.selector);
        sv.claimUnstaked();
        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(alice); sv.claimUnstaked();
        assertEq(fold.balanceOf(alice), 1000e18);
    }

    function test_onlyRewarderNotifies() public {
        vm.prank(alice); sv.stake(1e18);
        vm.expectRevert(StakingVaultV2.NotRewarder.selector);
        sv.notifyReward(address(usd), 1e6);
    }

    function test_onlyOwnerSetsRewarder() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        sv.setRewarder(rando, true);
    }

    function test_zeroAmountNotifyReverts() public {
        vm.prank(controller);
        vm.expectRevert(StakingVaultV2.ZeroAmount.selector);
        sv.notifyReward(address(usd), 0);
    }

    function test_rewardTokenCapEnforced() public {
        vm.prank(alice); sv.stake(1e18);
        for (uint256 i = 0; i < 16; i++) {
            MockUSD tok = new MockUSD();
            tok.mint(controller, 1e18);
            vm.prank(controller); tok.approve(address(sv), type(uint256).max);
            vm.prank(controller); sv.notifyReward(address(tok), 1e18);
        }
        MockUSD extra = new MockUSD();
        extra.mint(controller, 1e18);
        vm.prank(controller); extra.approve(address(sv), type(uint256).max);
        vm.prank(controller);
        vm.expectRevert(StakingVaultV2.TooManyRewardTokens.selector);
        sv.notifyReward(address(extra), 1e18);
    }

    function test_vaultAlwaysHoldsEnoughToPayEveryone() public {
        vm.prank(alice); sv.stake(300e18);
        vm.prank(bob); sv.stake(100e18);
        _notify(700e6);
        vm.warp(block.timestamp + DURATION);
        uint256 total = sv.earned(alice, address(usd)) + sv.earned(bob, address(usd));
        assertLe(total, usd.balanceOf(address(sv)), "vault must be solvent");
    }

    function testFuzz_neverPaysMoreThanNotified(uint96 stakeA, uint96 stakeB, uint96 reward, uint32 elapsed)
        public
    {
        stakeA = uint96(bound(stakeA, 1e6, 1e24));
        stakeB = uint96(bound(stakeB, 1e6, 1e24));
        reward = uint96(bound(reward, 1e6, 1e24));
        elapsed = uint32(bound(elapsed, 0, 4 * DURATION));

        deal(address(fold), alice, stakeA);
        deal(address(fold), bob, stakeB);
        usd.mint(controller, reward);

        vm.prank(alice); sv.stake(stakeA);
        vm.prank(bob); sv.stake(stakeB);
        vm.prank(controller); sv.notifyReward(address(usd), reward);

        vm.warp(block.timestamp + elapsed);
        uint256 total = sv.earned(alice, address(usd)) + sv.earned(bob, address(usd));
        assertLe(total, reward, "stream paid more than was notified");
        assertLe(total, usd.balanceOf(address(sv)), "vault must stay solvent");
    }
}
