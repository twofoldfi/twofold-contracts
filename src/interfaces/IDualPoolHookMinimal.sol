// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  IDualPoolHookMinimal                                                 ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityBucket} from "v4-hooks/alf/types/Distribution.sol";
import {DualPoolHook} from "v4-hooks/alf/DualPoolHook.sol";

interface IDualPoolHookMinimal {
    function initializePool(PoolKey calldata key, DualPoolHook.PoolConfig calldata config)
        external
        returns (int24 tick);

    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        returns (uint256 shares);

    function addLiquidity(
        PoolKey calldata key,
        uint256 sharesToMint,
        uint256 maxAmount0,
        uint256 maxAmount1,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function removeLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);

    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets) external;

    function setPoolLive(PoolKey calldata key, bool live) external;

    function setExternalDeposits(PoolKey calldata key, bool enabled) external;

    function emergencyRevokeVault(PoolKey calldata key) external;

    function refreshVaultApproval(PoolKey calldata key, Currency currency) external;

    function sharesOf(PoolKey calldata key, address user) external view returns (uint256);

    function previewWithdraw(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function previewDeposit(PoolKey calldata key, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;

    function acceptOwnership() external;
}
