// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                              ║
// ║  OperatorControllerV2                                                 ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityBucket} from "v4-hooks/alf/types/Distribution.sol";
import {DualPoolHook} from "v4-hooks/alf/DualPoolHook.sol";
import {IDualPoolHookMinimal} from "./interfaces/IDualPoolHookMinimal.sol";
import {VaultAllowlist} from "./VaultAllowlist.sol";
import {StakingVaultV2} from "./StakingVaultV2.sol";

contract OperatorControllerV2 is Ownable2Step {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    uint16 public constant MAX_SKIM_BPS = 2_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    IDualPoolHookMinimal public immutable hook;
    VaultAllowlist public immutable allowlist;
    StakingVaultV2 public immutable stakingVault;

    uint16 public skimBps;
    address public runner;

    mapping(PoolId => mapping(uint256 => LiquidityBucket[])) internal _shapeBuckets;
    mapping(PoolId => mapping(uint256 => bool)) public shapeApproved;
    mapping(PoolId => uint256) public nextShapeId;

    struct Basis {
        uint256 amount0;
        uint256 amount1;
    }

    mapping(PoolId => Basis) public basis;

    event RunnerSet(address indexed runner);
    event SkimBpsSet(uint16 skimBps);
    event Paused(bytes32 indexed poolId);
    event ShapeApproved(bytes32 indexed poolId, uint256 indexed shapeId);
    event ShapeApplied(bytes32 indexed poolId, uint256 indexed shapeId);
    event BasisRecorded(bytes32 indexed poolId, uint256 amount0, uint256 amount1);
    event Harvested(bytes32 indexed poolId, uint256 shares, uint256 amount0, uint256 amount1);

    error NotRunner();
    error ShapeNotApproved();
    error VaultNotAllowed(address vault);
    error SkimTooHigh();

    constructor(address multisig, address hook_, address allowlist_, address stakingVault_, uint16 skimBps_)
        Ownable(multisig)
    {
        if (skimBps_ > MAX_SKIM_BPS) revert SkimTooHigh();
        hook = IDualPoolHookMinimal(hook_);
        allowlist = VaultAllowlist(allowlist_);
        stakingVault = StakingVaultV2(stakingVault_);
        skimBps = skimBps_;
    }

    modifier onlyRunnerOrOwner() {
        if (msg.sender != runner && msg.sender != owner()) revert NotRunner();
        _;
    }

    function setRunner(address runner_) external onlyOwner {
        runner = runner_;
        emit RunnerSet(runner_);
    }

    function setSkimBps(uint16 newSkimBps) external onlyOwner {
        if (newSkimBps > MAX_SKIM_BPS) revert SkimTooHigh();
        skimBps = newSkimBps;
        emit SkimBpsSet(newSkimBps);
    }

    function approveShape(PoolKey calldata key, LiquidityBucket[] calldata buckets)
        external
        onlyOwner
        returns (uint256 shapeId)
    {
        PoolId poolId = key.toId();
        shapeId = nextShapeId[poolId]++;
        LiquidityBucket[] storage stored = _shapeBuckets[poolId][shapeId];
        for (uint256 i = 0; i < buckets.length; i++) {
            stored.push(buckets[i]);
        }
        shapeApproved[poolId][shapeId] = true;
        emit ShapeApproved(PoolId.unwrap(poolId), shapeId);
    }

    function retireShape(PoolKey calldata key, uint256 shapeId) external onlyOwner {
        shapeApproved[key.toId()][shapeId] = false;
    }

    function pause(PoolKey calldata key) external onlyRunnerOrOwner {
        hook.setPoolLive(key, false);
        emit Paused(PoolId.unwrap(key.toId()));
    }

    function applyShape(PoolKey calldata key, uint256 shapeId) external onlyRunnerOrOwner {
        PoolId poolId = key.toId();
        if (!shapeApproved[poolId][shapeId]) revert ShapeNotApproved();
        hook.setDistribution(key, _shapeBuckets[poolId][shapeId]);
        emit ShapeApplied(PoolId.unwrap(poolId), shapeId);
    }

    function initializePool(PoolKey calldata key, DualPoolHook.PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        address vault0 = address(config.vault0);
        address vault1 = address(config.vault1);
        if (vault0 != address(0) && !allowlist.isAllowed(vault0)) revert VaultNotAllowed(vault0);
        if (vault1 != address(0) && !allowlist.isAllowed(vault1)) revert VaultNotAllowed(vault1);
        tick = hook.initializePool(key, config);
    }

    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        onlyOwner
        returns (uint256 shares)
    {
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        IERC20 token1 = IERC20(Currency.unwrap(key.currency1));
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        token0.forceApprove(address(hook), amount0);
        token1.forceApprove(address(hook), amount1);
        shares = hook.bootstrap(key, amount0, amount1);
        _recordBasis(key);
    }

    function unpause(PoolKey calldata key) external onlyOwner {
        hook.setPoolLive(key, true);
    }

    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets) external onlyOwner {
        hook.setDistribution(key, buckets);
    }

    function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner {
        hook.setExternalDeposits(key, enabled);
    }

    function emergencyRevokeVault(PoolKey calldata key) external onlyOwner {
        hook.emergencyRevokeVault(key);
    }

    function refreshVaultApproval(PoolKey calldata key, Currency currency) external onlyOwner {
        hook.refreshVaultApproval(key, currency);
    }

    function acceptHookOwnership() external onlyOwner {
        hook.acceptOwnership();
    }

    function transferHookOwnership(address newOwner) external onlyOwner {
        hook.transferOwnership(newOwner);
    }

    function _currentValue(PoolKey calldata key) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 sharesHeld = hook.sharesOf(key, address(this));
        return hook.previewWithdraw(key, sharesHeld);
    }

    function recordBasis(PoolKey calldata key) external onlyOwner {
        _recordBasis(key);
    }

    function _recordBasis(PoolKey calldata key) internal {
        (uint256 amount0, uint256 amount1) = _currentValue(key);
        basis[key.toId()] = Basis(amount0, amount1);
        emit BasisRecorded(PoolId.unwrap(key.toId()), amount0, amount1);
    }

    function harvest(PoolKey calldata key, uint256 minAmount0, uint256 minAmount1, uint256 deadline)
        external
        onlyOwner
    {
        PoolId poolId = key.toId();
        uint256 sharesHeld = hook.sharesOf(key, address(this));
        (uint256 value0, uint256 value1) = hook.previewWithdraw(key, sharesHeld);

        Basis memory b = basis[poolId];
        uint256 gain0 = value0 > b.amount0 ? value0 - b.amount0 : 0;
        uint256 gain1 = value1 > b.amount1 ? value1 - b.amount1 : 0;
        if (gain0 == 0 && gain1 == 0) return;

        uint256 skimValue0 = (gain0 * skimBps) / BPS_DENOMINATOR;
        uint256 skimValue1 = (gain1 * skimBps) / BPS_DENOMINATOR;
        uint256 bound0 = value0 > 0 ? (sharesHeld * skimValue0) / value0 : 0;
        uint256 bound1 = value1 > 0 ? (sharesHeld * skimValue1) / value1 : 0;
        uint256 skimShares = bound0 < bound1 ? bound0 : bound1;
        if (skimShares == 0) return;

        (uint256 amount0, uint256 amount1) = hook.removeLiquidity(key, skimShares, minAmount0, minAmount1, deadline);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        if (amount0 > 0) {
            IERC20(token0).forceApprove(address(stakingVault), amount0);
            stakingVault.notifyReward(token0, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).forceApprove(address(stakingVault), amount1);
            stakingVault.notifyReward(token1, amount1);
        }

        (uint256 postAmount0, uint256 postAmount1) = _currentValue(key);
        basis[poolId] = Basis(postAmount0, postAmount1);

        emit Harvested(PoolId.unwrap(poolId), skimShares, amount0, amount1);
    }
}
