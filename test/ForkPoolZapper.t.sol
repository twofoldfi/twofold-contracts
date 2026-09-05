// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
// Fork tests for PoolZapper against real Robinhood Chain state (anvil fork on
// http://localhost:8547, or FORK_RPC_8547).
//
// Real contracts from fork state:
//   PoolManager  0x8366a39CC670B4001A1121B8F6A443A643e40951
//   DualPoolHook 0x127B3f3b7769f659C5eDBfF8b4005443f19FAAc0
//   WETH         0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
//   USDG         0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
//   TSLA         0x322F0929c4625eD5bAd873c95208D54E1c003b2d
//
// Our pools: fee 3000 / spacing 60 / hooks = DualPoolHook.
// Reference markets (hookless): TSLA/USDG fee 3000/60, WETH/USDG fee 200/4.
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolZapper, IDualPoolHookZap, IWETH9} from "../src/PoolZapper.sol";

interface IHookPreview {
    function previewDeposit(PoolKey calldata key, uint256 shares) external view returns (uint256, uint256);
    function sharesOf(PoolKey calldata key, address user) external view returns (uint256);
}

interface IQuoterMin {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteExactSingleParams calldata params) external returns (uint256 amountOut, uint256 gasEstimate);
}

contract ForkPoolZapperTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant HOOK = 0x127B3f3b7769f659C5eDBfF8b4005443f19FAAc0;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    PoolZapper zapper;
    PoolKey tslaPool;
    PoolKey wethPool;
    PoolKey tslaRef;
    PoolKey wethRef;
    address user = address(0xBEEF);
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_8547", string("http://localhost:8547"));
        try vm.createSelectFork(rpc) { forked = true; } catch { return; }
        zapper = new PoolZapper(
            IPoolManager(POOL_MANAGER), IDualPoolHookZap(HOOK), IWETH9(WETH), IERC20(USDG)
        );
        tslaPool = PoolKey(Currency.wrap(TSLA), Currency.wrap(USDG), 3000, 60, IHooks(HOOK));
        wethPool = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 3000, 60, IHooks(HOOK));
        tslaRef = PoolKey(Currency.wrap(TSLA), Currency.wrap(USDG), 3000, 60, IHooks(address(0)));
        wethRef = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 200, 4, IHooks(address(0)));
        vm.deal(user, 100 ether);
    }

    modifier onFork() {
        if (!forked) { vm.skip(true); }
        _;
    }

    // Mirrors the frontend plan: quote ETH->USDG, read the pool ratio via
    // previewDeposit, split the USDG budget, quote the asset buy, size shares
    // with a 0.5% haircut so ratio drift between quote and execution cannot
    // revert the deposit.
    function _planEthIntoTsla(uint256 ethIn)
        internal
        returns (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares)
    {
        (uint256 usdgOut,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(wethRef, true, uint128(ethIn), "")
        );
        minUsdg = usdgOut * 995 / 1000;
        (uint256 wantTsla, uint256 wantUsdg) = IHookPreview(HOOK).previewDeposit(tslaPool, 1e18);
        (uint256 tslaUnit,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(tslaRef, false, uint128(1e6), "")
        );
        uint256 tslaCostUsdg = wantTsla * 1e6 / tslaUnit;
        usdgForAsset = usdgOut * tslaCostUsdg / (tslaCostUsdg + wantUsdg);
        (uint256 tslaOut,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(tslaRef, false, uint128(usdgForAsset), "")
        );
        minAsset = tslaOut * 995 / 1000;
        uint256 byTsla = minAsset * 1e18 / wantTsla;
        uint256 byUsdg = (usdgOut - usdgForAsset) * 1e18 / wantUsdg;
        shares = (byTsla < byUsdg ? byTsla : byUsdg) * 995 / 1000;
    }

    function test_zapInETH_tslaPool_creditsSharesAndRefunds() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares) = _planEthIntoTsla(ethIn);
        assertGt(shares, 0);
        vm.prank(user);
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg, usdgForAsset, minAsset, shares, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
        bytes32 pid = PoolId.unwrap(tslaPool.toId());
        assertEq(zapper.sharesOf(pid, user), shares);
        assertEq(IHookPreview(HOOK).sharesOf(tslaPool, address(zapper)), shares);
        assertEq(IERC20(WETH).balanceOf(address(zapper)), 0);
        assertEq(IERC20(USDG).balanceOf(address(zapper)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zapper)), 0);
        assertEq(address(zapper).balance, 0);
        assertGt(IERC20(USDG).balanceOf(user) + IERC20(TSLA).balanceOf(user), 0);
    }

    function test_zapOut_returnsBothLegs() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares) = _planEthIntoTsla(ethIn);
        vm.prank(user);
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg, usdgForAsset, minAsset, shares, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
        vm.roll(block.number + 1);
        uint256 t0 = IERC20(TSLA).balanceOf(user);
        uint256 u0 = IERC20(USDG).balanceOf(user);
        vm.prank(user);
        zapper.zapOut(tslaPool, shares, 1, 1, block.timestamp + 300);
        assertEq(zapper.sharesOf(PoolId.unwrap(tslaPool.toId()), user), 0);
        assertGt(IERC20(TSLA).balanceOf(user), t0);
        assertGt(IERC20(USDG).balanceOf(user), u0);
        assertEq(IHookPreview(HOOK).sharesOf(tslaPool, address(zapper)), 0);
    }

    function test_zapOut_moreThanHeld_reverts() public onFork {
        vm.prank(user);
        vm.expectRevert(PoolZapper.InsufficientShares.selector);
        zapper.zapOut(tslaPool, 1, 0, 0, block.timestamp + 300);
    }

    function test_zapOut_cannotBurnAnotherUsersShares() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares) = _planEthIntoTsla(ethIn);
        vm.prank(user);
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg, usdgForAsset, minAsset, shares, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
        vm.roll(block.number + 1);
        address thief = address(0xBAD);
        vm.prank(thief);
        vm.expectRevert(PoolZapper.InsufficientShares.selector);
        zapper.zapOut(tslaPool, shares, 0, 0, block.timestamp + 300);
    }

    function test_zapInETH_minUsdgTooHigh_revertsWholeTx() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg,,, uint256 shares) = _planEthIntoTsla(ethIn);
        vm.prank(user);
        vm.expectRevert(PoolZapper.SwapOutputBelowMin.selector);
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg * 2, 0, 0, shares, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
        assertEq(IERC20(WETH).balanceOf(address(zapper)), 0);
        assertEq(user.balance, 100 ether);
    }

    function test_zapInETH_wethPool_keepsWethLeg() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 wantWeth, uint256 wantUsdg) = IHookPreview(HOOK).previewDeposit(wethPool, 1e15);
        assertGt(wantWeth + wantUsdg, 0);
        (uint256 usdgUnit,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(wethRef, true, uint128(1e18), "")
        );
        uint256 wethCostUsdg = wantWeth * usdgUnit / 1e18;
        uint256 sellWei = ethIn * wantUsdg / (wantUsdg + wethCostUsdg);
        (uint256 usdgOut,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(wethRef, true, uint128(sellWei), "")
        );
        uint256 byW = (ethIn - sellWei) * 1e15 / wantWeth;
        uint256 byU = usdgOut * 995 / 1000 * 1e15 / wantUsdg;
        uint256 shares = (byW < byU ? byW : byU) * 995 / 1000;
        vm.prank(user);
        zapper.zapInETH{value: ethIn}(
            wethPool, wethRef, wethRef, sellWei, usdgOut * 995 / 1000, 0, 0, shares, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
        assertEq(zapper.sharesOf(PoolId.unwrap(wethPool.toId()), user), shares);
        assertGt(user.balance, 99 ether - sellWei);
    }

    function test_zapInUSDG_tslaPool() public onFork {
        deal(USDG, user, 1_000e6);
        uint256 usdgIn = 500e6;
        (uint256 wantTsla, uint256 wantUsdg) = IHookPreview(HOOK).previewDeposit(tslaPool, 1e18);
        (uint256 tslaUnit,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(tslaRef, false, uint128(1e6), "")
        );
        uint256 tslaCostUsdg = wantTsla * 1e6 / tslaUnit;
        uint256 usdgForAsset = usdgIn * tslaCostUsdg / (tslaCostUsdg + wantUsdg);
        (uint256 tslaOut,) = IQuoterMin(QUOTER).quoteExactInputSingle(
            IQuoterMin.QuoteExactSingleParams(tslaRef, false, uint128(usdgForAsset), "")
        );
        uint256 minAsset = tslaOut * 995 / 1000;
        uint256 byT = minAsset * 1e18 / wantTsla;
        uint256 byU = (usdgIn - usdgForAsset) * 1e18 / wantUsdg;
        uint256 shares = (byT < byU ? byT : byU) * 995 / 1000;
        vm.startPrank(user);
        IERC20(USDG).approve(address(zapper), usdgIn);
        zapper.zapInUSDG(tslaPool, tslaRef, usdgIn, usdgForAsset, minAsset, shares, type(uint256).max, type(uint256).max, block.timestamp + 300);
        vm.stopPrank();
        assertEq(zapper.sharesOf(PoolId.unwrap(tslaPool.toId()), user), shares);
        assertEq(IERC20(USDG).balanceOf(address(zapper)), 0);
        assertEq(IERC20(TSLA).balanceOf(address(zapper)), 0);
    }

    function test_zapInETH_tightDepositMax_revertsWholeTx() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares) = _planEthIntoTsla(ethIn);
        vm.prank(user);
        vm.expectRevert();
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg, usdgForAsset, minAsset, shares, type(uint256).max, 1, block.timestamp + 300
        );
        assertEq(user.balance, 100 ether);
    }

    function test_zapInETH_tightDepositMax0_revertsWholeTx() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares) = _planEthIntoTsla(ethIn);
        vm.prank(user);
        vm.expectRevert();
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg, usdgForAsset, minAsset, shares, 1, type(uint256).max, block.timestamp + 300
        );
        assertEq(user.balance, 100 ether);
    }

    function test_unlockCallback_onlyPoolManager() public onFork {
        vm.prank(user);
        vm.expectRevert(PoolZapper.NotPoolManager.selector);
        zapper.unlockCallback(abi.encode(wethRef, Currency.wrap(WETH), uint256(1), uint256(0)));
    }

    function test_1155_transfer_movesExitRights() public onFork {
        uint256 ethIn = 1 ether;
        (uint256 minUsdg, uint256 usdgForAsset, uint256 minAsset, uint256 shares) = _planEthIntoTsla(ethIn);
        vm.prank(user);
        zapper.zapInETH{value: ethIn}(
            tslaPool, wethRef, tslaRef, ethIn, minUsdg, usdgForAsset, minAsset, shares, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
        vm.roll(block.number + 1);
        address friend = address(0xF111);
        uint256 id = uint256(PoolId.unwrap(tslaPool.toId()));
        vm.prank(user);
        zapper.safeTransferFrom(user, friend, id, shares, "");
        vm.prank(user);
        vm.expectRevert(PoolZapper.InsufficientShares.selector);
        zapper.zapOut(tslaPool, shares, 0, 0, block.timestamp + 300);
        vm.prank(friend);
        zapper.zapOut(tslaPool, shares, 1, 1, block.timestamp + 300);
        assertGt(IERC20(TSLA).balanceOf(friend), 0);
        assertGt(IERC20(USDG).balanceOf(friend), 0);
    }

    function test_receive_rejectsPlainEth() public onFork {
        vm.prank(user);
        (bool ok,) = address(zapper).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_sellExceedsValue_reverts() public onFork {
        vm.prank(user);
        vm.expectRevert(PoolZapper.SellExceedsValue.selector);
        zapper.zapInETH{value: 1 ether}(
            tslaPool, wethRef, tslaRef, 2 ether, 0, 0, 0, 1, type(uint256).max, type(uint256).max, block.timestamp + 300
        );
    }
}
