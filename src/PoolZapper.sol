// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  PoolZapper                                                           ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IDualPoolHookZap {
    function addLiquidity(PoolKey calldata key, uint256 sharesToMint, uint256 maxAmount0, uint256 maxAmount1, uint256 deadline) external returns (uint256, uint256);
    function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn, uint256 minAmount0, uint256 minAmount1, uint256 deadline) external returns (uint256, uint256);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract PoolZapper is ERC1155, IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    error NotPoolManager();
    error NotWETH();
    error SwapOutputBelowMin();
    error SellExceedsValue();
    error NoValue();
    error InsufficientShares();
    error EthSendFailed();

    event ZappedIn(bytes32 indexed poolId, address indexed user, uint256 shares, uint256 ethIn, uint256 usdgIn);
    event ZappedOut(bytes32 indexed poolId, address indexed user, uint256 shares, uint256 amount0, uint256 amount1);

    IPoolManager public immutable poolManager;
    IDualPoolHookZap public immutable hook;
    IWETH9 public immutable weth;
    IERC20 public immutable usdg;

    constructor(IPoolManager _poolManager, IDualPoolHookZap _hook, IWETH9 _weth, IERC20 _usdg) ERC1155("") {
        poolManager = _poolManager;
        hook = _hook;
        weth = _weth;
        usdg = _usdg;
    }

    function name() external pure returns (string memory) {
        return "Twofold LP";
    }

    function symbol() external pure returns (string memory) {
        return "TWO-LP";
    }

    function sharesOf(bytes32 poolId, address user) external view returns (uint256) {
        return balanceOf(user, uint256(poolId));
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert NotWETH();
    }

    function zapInETH(
        PoolKey calldata poolKey,
        PoolKey calldata wethRef,
        PoolKey calldata assetRef,
        uint256 sellWei,
        uint256 minUsdgOut,
        uint256 usdgForAsset,
        uint256 minAssetOut,
        uint256 sharesToMint,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 deadline
    ) external payable nonReentrant {
        if (msg.value == 0) revert NoValue();
        if (sellWei > msg.value) revert SellExceedsValue();
        weth.deposit{value: msg.value}();
        if (sellWei > 0) {
            _swap(wethRef, Currency.wrap(address(weth)), sellWei, minUsdgOut);
        }
        if (usdgForAsset > 0) {
            _swap(assetRef, Currency.wrap(address(usdg)), usdgForAsset, minAssetOut);
        }
        _depositAndLedger(poolKey, sharesToMint, maxAmount0, maxAmount1, deadline);
        emit ZappedIn(PoolId.unwrap(poolKey.toId()), msg.sender, sharesToMint, msg.value, 0);
        _refundAll(poolKey);
    }

    function zapInUSDG(
        PoolKey calldata poolKey,
        PoolKey calldata assetRef,
        uint256 usdgIn,
        uint256 usdgForAsset,
        uint256 minAssetOut,
        uint256 sharesToMint,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 deadline
    ) external nonReentrant {
        if (usdgIn == 0) revert NoValue();
        usdg.safeTransferFrom(msg.sender, address(this), usdgIn);
        if (usdgForAsset > 0) {
            _swap(assetRef, Currency.wrap(address(usdg)), usdgForAsset, minAssetOut);
        }
        _depositAndLedger(poolKey, sharesToMint, maxAmount0, maxAmount1, deadline);
        emit ZappedIn(PoolId.unwrap(poolKey.toId()), msg.sender, sharesToMint, 0, usdgIn);
        _refundAll(poolKey);
    }

    function zapOut(
        PoolKey calldata poolKey,
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    ) external nonReentrant {
        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        uint256 held = balanceOf(msg.sender, uint256(poolId));
        if (sharesToBurn == 0 || sharesToBurn > held) revert InsufficientShares();
        _burn(msg.sender, uint256(poolId), sharesToBurn);
        (uint256 amount0, uint256 amount1) =
            hook.removeLiquidity(poolKey, sharesToBurn, minAmount0, minAmount1, deadline);
        if (amount0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(msg.sender, amount1);
        emit ZappedOut(poolId, msg.sender, sharesToBurn, amount0, amount1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory ref, Currency inCur, uint256 amountIn, uint256 minOut) =
            abi.decode(data, (PoolKey, Currency, uint256, uint256));
        bool zeroForOne = Currency.unwrap(inCur) == Currency.unwrap(ref.currency0);
        Currency outCur = zeroForOne ? ref.currency1 : ref.currency0;
        BalanceDelta delta = poolManager.swap(
            ref,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 outSigned = zeroForOne ? delta.amount1() : delta.amount0();
        if (outSigned < 0) revert SwapOutputBelowMin();
        uint256 outAmount = uint256(int256(outSigned));
        if (outAmount < minOut) revert SwapOutputBelowMin();
        poolManager.sync(inCur);
        IERC20(Currency.unwrap(inCur)).safeTransfer(address(poolManager), amountIn);
        poolManager.settle();
        poolManager.take(outCur, address(this), outAmount);
        return abi.encode(outAmount);
    }

    function _swap(PoolKey calldata ref, Currency inCur, uint256 amountIn, uint256 minOut) internal returns (uint256) {
        bytes memory result = poolManager.unlock(abi.encode(ref, inCur, amountIn, minOut));
        return abi.decode(result, (uint256));
    }

    function _depositAndLedger(PoolKey calldata poolKey, uint256 sharesToMint, uint256 maxAmount0, uint256 maxAmount1, uint256 deadline) internal {
        IERC20 t0 = IERC20(Currency.unwrap(poolKey.currency0));
        IERC20 t1 = IERC20(Currency.unwrap(poolKey.currency1));
        uint256 b0 = t0.balanceOf(address(this));
        uint256 b1 = t1.balanceOf(address(this));
        if (maxAmount0 < b0) b0 = maxAmount0;
        if (maxAmount1 < b1) b1 = maxAmount1;
        t0.forceApprove(address(hook), b0);
        t1.forceApprove(address(hook), b1);
        hook.addLiquidity(poolKey, sharesToMint, b0, b1, deadline);
        t0.forceApprove(address(hook), 0);
        t1.forceApprove(address(hook), 0);
        _mint(msg.sender, uint256(PoolId.unwrap(poolKey.toId())), sharesToMint, "");
    }

    function _refundAll(PoolKey calldata poolKey) internal {
        _refundToken(Currency.unwrap(poolKey.currency0));
        _refundToken(Currency.unwrap(poolKey.currency1));
        _refundToken(address(usdg));
        uint256 wbal = weth.balanceOf(address(this));
        if (wbal > 0) {
            weth.withdraw(wbal);
            (bool ok,) = msg.sender.call{value: wbal}("");
            if (!ok) revert EthSendFailed();
        }
    }

    function _refundToken(address token) internal {
        if (token == address(weth)) return;
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).safeTransfer(msg.sender, bal);
    }
}
