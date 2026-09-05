// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
// VERIFIED SIGNATURES (Task 5 brief, Step 1) — read against the real vendored
// source, not assumed. Sources:
//   lib/v4-hooks-public/src/alf/base/PoolVault.sol
//   lib/v4-hooks-public/src/alf/DualPoolHook.sol
//   lib/v4-hooks-public/src/alf/base/OwnedALFHook.sol
//   lib/v4-hooks-public/src/alf/types/Distribution.sol
//
// PoolVault (abstract base of DualPoolHook):
//   function totalShares(PoolId poolId) external view returns (uint256)
//   function userShares(PoolId poolId, address user) external view returns (uint256)
//   function totalAssets(PoolKey calldata key) external view returns (uint256 amount0, uint256 amount1)
//   function previewDeposit(PoolKey calldata key, uint256 shares) external view returns (uint256 amount0, uint256 amount1)
//   function previewWithdraw(PoolKey calldata key, uint256 shares) external view returns (uint256 amount0, uint256 amount1)
//   function vaults(PoolId poolId, Currency currency) external view returns (IERC4626)
//   function minDepositBlocks(PoolId) external view returns (uint64)   // public mapping getter
//
//   _bootstrap(VaultId, asset0, asset1, from, to, amount0, amount1) — internal. DualPoolHook's
//   external `bootstrap` calls `_bootstrap(key, msg.sender, msg.sender, amount0, amount1)`, and
//   `_pullAsset` inside it does `IERC20(asset).safeTransferFrom(from, address(this), want)`.
//   CONFIRMED: `from` == `msg.sender` of the *hook's* `bootstrap()` call. Since OperatorControllerV2
//   is the hook's owner and calls `hook.bootstrap(...)` itself, the hook pulls tokens from the
//   CONTROLLER's own balance, not from the original EOA that called the controller. The brief's
//   assumption is verified correct: the controller's `bootstrap()` wrapper must first pull both
//   legs from its own caller (`safeTransferFrom(msg.sender, address(this), amountN)`), then
//   `forceApprove` the hook for `amountN`, then call `hook.bootstrap(key, amount0, amount1)`.
//   Same pull-from-msg.sender pattern applies to `addLiquidity` (`_deposit(key, msg.sender,
//   msg.sender, sharesToMint)`), but `addLiquidity` is NOT `onlyOwner` on the hook — external
//   depositors call the hook directly when `allowExternalDeposits` is set, so it needs no
//   controller wrapper for Task 5's auth surface.
//
// DualPoolHook (contract DualPoolHook is OwnedALFHook, PoolVault, ReentrancyGuardTransient, IUnlockCallback):
//   struct PoolConfig {                                    // nested inside DualPoolHook — must be
//       uint160 sqrtPriceX96;                               // referenced as DualPoolHook.PoolConfig,
//       LiquidityBucket[] distribution;                      // cannot be redeclared standalone.
//       bool allowExternalDeposits;
//       IERC4626 vault0;
//       IERC4626 vault1;
//       uint64 minDepositBlocks;
//   }
//   function initializePool(PoolKey calldata key, PoolConfig calldata config) external onlyOwner returns (int24 tick)
//   function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1) external onlyOwner nonReentrant whenJITNotInProgress returns (uint256 shares)
//   function addLiquidity(PoolKey calldata key, uint256 sharesToMint, uint256 maxAmount0, uint256 maxAmount1, uint256 deadline) external nonReentrant whenJITNotInProgress checkDeadline(deadline) returns (uint256 amount0, uint256 amount1)
//   function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn, uint256 minAmount0, uint256 minAmount1, uint256 deadline) external nonReentrant whenJITNotInProgress checkDeadline(deadline) returns (uint256 amount0, uint256 amount1)
//   function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets) external onlyOwner whenJITNotInProgress
//   function refreshVaultApproval(PoolKey calldata key, Currency currency) external onlyOwner whenJITNotInProgress
//   function emergencyRevokeVault(PoolKey calldata key) external onlyOwner nonReentrant whenJITNotInProgress
//   function setExternalDeposits(PoolKey calldata key, bool enabled) external onlyOwner whenJITNotInProgress
//   function setPoolLive(PoolKey calldata key, bool live) external onlyOwner whenJITNotInProgress
//   function sharesOf(PoolKey calldata key, address user) external view returns (uint256)
//   Ownable2Step via OwnedALFHook: standard OZ `transferOwnership(address)` / `acceptOwnership()`;
//   `renounceOwnership()` is overridden to always revert (disabled) — not part of our wrapper set.
//
// LiquidityBucket (top-level free struct, lib/v4-hooks-public/src/alf/types/Distribution.sol):
//   struct LiquidityBucket { int24 tickLower; int24 tickUpper; uint16 weightBps; }
//   MAX_BUCKETS = 8, weights must sum to 10_000 (enforced hook-side, not by the controller).
//
// Adjustments made to the brief's interface block based on the above:
//   - IDualPoolHookMinimal.initializePool takes `DualPoolHook.PoolConfig calldata`, requiring an
//     import of DualPoolHook itself (PoolConfig has no standalone existence). This does NOT
//     import AllowlistedFactory anywhere in the same file/graph, so the CLAUDE.md build invariant
//     (never import both DualPoolHook and AllowlistedFactory into one file) is respected.
//   - `addLiquidity`/`removeLiquidity` are included in IDualPoolHookMinimal (harmless — matches
//     the real hook's calldata-shaped external ABI) but OperatorControllerV2 does NOT wrap them,
//     since they are not owner-gated on the hook.
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityBucket} from "v4-hooks/alf/types/Distribution.sol";
import {DualPoolHook} from "v4-hooks/alf/DualPoolHook.sol";
import {IDualPoolHookMinimal} from "../src/interfaces/IDualPoolHookMinimal.sol";
import {OperatorControllerV2} from "../src/OperatorControllerV2.sol";
import {VaultAllowlist} from "../src/VaultAllowlist.sol";
import {StakingVaultV2} from "../src/StakingVaultV2.sol";

contract MockERC20V2 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Records every call made through the minimal interface so tests can assert on args.
contract MockDualPoolHookV2 is IDualPoolHookMinimal {
    using PoolIdLibrary for PoolKey;

    address public owner_;

    uint256 public initializeCalls;
    address public lastInitVault0;
    address public lastInitVault1;

    uint256 public bootstrapCalls;
    uint256 public lastBootstrapAmount0;
    uint256 public lastBootstrapAmount1;

    mapping(bytes32 => bool) public poolLive;
    uint256 public setPoolLiveCalls;

    mapping(bytes32 => LiquidityBucket[]) internal _lastDistribution;
    uint256 public setDistributionCalls;

    uint256 public setExternalDepositsCalls;
    uint256 public emergencyRevokeVaultCalls;
    uint256 public refreshVaultApprovalCalls;
    uint256 public transferOwnershipCalls;
    uint256 public acceptOwnershipCalls;
    address public lastTransferOwnershipTarget;

    // Configurable read views (Task 6: harvest).
    uint256 public mockShares;
    uint256 public mockPreviewAmount0;
    uint256 public mockPreviewAmount1;

    // Configurable removeLiquidity behavior + call recording (Task 6: harvest).
    uint256 public mockRemoveAmount0;
    uint256 public mockRemoveAmount1;
    uint256 public removeLiquidityCalls;
    uint256 public lastRemoveShares;
    uint256 public lastRemoveMinAmount0;
    uint256 public lastRemoveMinAmount1;
    uint256 public lastRemoveDeadline;

    constructor(address initialOwner) {
        owner_ = initialOwner;
    }

    function setSharesOf(uint256 shares) external {
        mockShares = shares;
    }

    function setPreviewWithdraw(uint256 amount0, uint256 amount1) external {
        mockPreviewAmount0 = amount0;
        mockPreviewAmount1 = amount1;
    }

    /// @dev `amount0`/`amount1` are transferred out on the next `removeLiquidity` call; the mock
    ///      must hold sufficient balance of `key.currency0`/`key.currency1` (mint to the mock in
    ///      the test's setUp).
    function setRemoveLiquidityReturn(uint256 amount0, uint256 amount1) external {
        mockRemoveAmount0 = amount0;
        mockRemoveAmount1 = amount1;
    }

    function initializePool(PoolKey calldata key, DualPoolHook.PoolConfig calldata config)
        external
        override
        returns (int24 tick)
    {
        initializeCalls++;
        lastInitVault0 = address(config.vault0);
        lastInitVault1 = address(config.vault1);
        key.toId(); // touch, avoid unused warning
        return 0;
    }

    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        override
        returns (uint256 shares)
    {
        // Mirror the real hook's pull pattern: pulls from msg.sender (the controller).
        if (amount0 > 0) {
            ERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            ERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);
        }
        bootstrapCalls++;
        lastBootstrapAmount0 = amount0;
        lastBootstrapAmount1 = amount1;
        return 1_000e18;
    }

    function addLiquidity(PoolKey calldata, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function removeLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 minAmount0,
        uint256 minAmount1,
        uint256 deadline
    ) external override returns (uint256 amount0, uint256 amount1) {
        removeLiquidityCalls++;
        lastRemoveShares = sharesToBurn;
        lastRemoveMinAmount0 = minAmount0;
        lastRemoveMinAmount1 = minAmount1;
        lastRemoveDeadline = deadline;

        amount0 = mockRemoveAmount0;
        amount1 = mockRemoveAmount1;
        if (amount0 > 0) ERC20(Currency.unwrap(key.currency0)).transfer(msg.sender, amount0);
        if (amount1 > 0) ERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, amount1);
    }

    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets) external override {
        setDistributionCalls++;
        bytes32 poolId = PoolId.unwrap(key.toId());
        delete _lastDistribution[poolId];
        for (uint256 i = 0; i < buckets.length; i++) {
            _lastDistribution[poolId].push(buckets[i]);
        }
    }

    function lastDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _lastDistribution[PoolId.unwrap(poolId)];
    }

    function setPoolLive(PoolKey calldata key, bool live) external override {
        setPoolLiveCalls++;
        poolLive[PoolId.unwrap(key.toId())] = live;
    }

    function setExternalDeposits(PoolKey calldata, bool) external override {
        setExternalDepositsCalls++;
    }

    function emergencyRevokeVault(PoolKey calldata) external override {
        emergencyRevokeVaultCalls++;
    }

    function refreshVaultApproval(PoolKey calldata, Currency) external override {
        refreshVaultApprovalCalls++;
    }

    function sharesOf(PoolKey calldata, address) external view override returns (uint256) {
        return mockShares;
    }

    function previewWithdraw(PoolKey calldata, uint256) external view override returns (uint256, uint256) {
        return (mockPreviewAmount0, mockPreviewAmount1);
    }

    function previewDeposit(PoolKey calldata, uint256) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    function owner() external view override returns (address) {
        return owner_;
    }

    function transferOwnership(address newOwner) external override {
        transferOwnershipCalls++;
        lastTransferOwnershipTarget = newOwner;
    }

    function acceptOwnership() external override {
        acceptOwnershipCalls++;
        owner_ = msg.sender;
    }
}

contract OperatorControllerV2Test is Test {
    using PoolIdLibrary for PoolKey;

    OperatorControllerV2 internal controller;
    MockDualPoolHookV2 internal mockHook;
    VaultAllowlist internal allowlist;
    StakingVaultV2 internal stakingVault;
    MockERC20V2 internal token0;
    MockERC20V2 internal token1;

    address internal multisig = address(0xA11CE);
    address internal runner = address(0xB0B);
    address internal stranger = address(0xC0FFEE);
    address internal allowedVault = address(0xD00D);
    address internal disallowedVault = address(0xBAD);

    PoolKey internal key;

    function setUp() public {
        token0 = new MockERC20V2();
        token1 = new MockERC20V2();

        mockHook = new MockDualPoolHookV2(address(this));

        allowlist = new VaultAllowlist(multisig);
        vm.prank(multisig);
        allowlist.setAllowed(allowedVault, true);

        // StakingVaultV2 needs a stake token; a MockERC20V2 stands in fine, harvest wiring is Task 6.
        stakingVault = new StakingVaultV2(multisig, address(new MockERC20V2()), 0, 7 days);

        controller =
            new OperatorControllerV2(multisig, address(mockHook), address(allowlist), address(stakingVault), 500);

        vm.prank(multisig);
        controller.setRunner(runner);

        (Currency c0, Currency c1) = address(token0) < address(token1)
            ? (Currency.wrap(address(token0)), Currency.wrap(address(token1)))
            : (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(mockHook))});
    }

    function _buckets() internal pure returns (LiquidityBucket[] memory b) {
        b = new LiquidityBucket[](1);
        b[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
    }

    function _config(address vault0, address vault1) internal pure returns (DualPoolHook.PoolConfig memory) {
        LiquidityBucket[] memory dist = new LiquidityBucket[](1);
        dist[0] = LiquidityBucket({tickLower: -60, tickUpper: 60, weightBps: 10_000});
        return DualPoolHook.PoolConfig({
            sqrtPriceX96: 0,
            distribution: dist,
            allowExternalDeposits: false,
            vault0: IERC4626(vault0),
            vault1: IERC4626(vault1),
            minDepositBlocks: 0
        });
    }

    // ── Runner surface ──────────────────────────────────────────────────────

    function test_runnerCanPause() public {
        vm.prank(runner);
        controller.pause(key);
        assertEq(mockHook.setPoolLiveCalls(), 1);
        assertFalse(mockHook.poolLive(PoolId.unwrap(key.toId())));
    }

    function test_runnerCannotUnpause() public {
        vm.prank(runner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, runner));
        controller.unpause(key);
    }

    function test_runnerCanApplyApprovedShape() public {
        LiquidityBucket[] memory buckets = _buckets();
        vm.prank(multisig);
        uint256 shapeId = controller.approveShape(key, buckets);

        vm.prank(runner);
        controller.applyShape(key, shapeId);

        assertEq(mockHook.setDistributionCalls(), 1);
        LiquidityBucket[] memory recorded = mockHook.lastDistribution(key.toId());
        assertEq(recorded.length, buckets.length);
        assertEq(recorded[0].tickLower, buckets[0].tickLower);
        assertEq(recorded[0].tickUpper, buckets[0].tickUpper);
        assertEq(recorded[0].weightBps, buckets[0].weightBps);
    }

    function test_runnerCannotApplyUnknownShape() public {
        vm.prank(runner);
        vm.expectRevert(OperatorControllerV2.ShapeNotApproved.selector);
        controller.applyShape(key, 0);
    }

    function test_runnerCannotApplyRetiredShape() public {
        vm.startPrank(multisig);
        uint256 shapeId = controller.approveShape(key, _buckets());
        controller.retireShape(key, shapeId);
        vm.stopPrank();

        vm.prank(runner);
        vm.expectRevert(OperatorControllerV2.ShapeNotApproved.selector);
        controller.applyShape(key, shapeId);
    }

    function test_nonRunnerNonOwnerCannotPause() public {
        vm.prank(stranger);
        vm.expectRevert(OperatorControllerV2.NotRunner.selector);
        controller.pause(key);
    }

    // ── Owner pass-throughs ─────────────────────────────────────────────────

    function test_ownerCanSetArbitraryDistribution() public {
        LiquidityBucket[] memory buckets = _buckets();
        vm.prank(multisig);
        controller.setDistribution(key, buckets);
        assertEq(mockHook.setDistributionCalls(), 1);
    }

    function test_initializePoolGatedOnAllowlist() public {
        DualPoolHook.PoolConfig memory config = _config(disallowedVault, address(0));
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(OperatorControllerV2.VaultNotAllowed.selector, disallowedVault));
        controller.initializePool(key, config);
        assertEq(mockHook.initializeCalls(), 0);
    }

    function test_initializePoolZeroVaultOk() public {
        DualPoolHook.PoolConfig memory config = _config(address(0), address(0));
        vm.prank(multisig);
        controller.initializePool(key, config);
        assertEq(mockHook.initializeCalls(), 1);
        assertEq(mockHook.lastInitVault0(), address(0));
        assertEq(mockHook.lastInitVault1(), address(0));
    }

    function test_initializePoolAllowedVaultOk() public {
        DualPoolHook.PoolConfig memory config = _config(allowedVault, address(0));
        vm.prank(multisig);
        controller.initializePool(key, config);
        assertEq(mockHook.initializeCalls(), 1);
        assertEq(mockHook.lastInitVault0(), allowedVault);
    }

    function test_transferHookOwnershipOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        controller.transferHookOwnership(stranger);

        vm.prank(multisig);
        controller.transferHookOwnership(stranger);
        assertEq(mockHook.transferOwnershipCalls(), 1);
        assertEq(mockHook.lastTransferOwnershipTarget(), stranger);
    }

    function test_bootstrapPullsFromCallerAndApprovesHook() public {
        token0.mint(multisig, 1_000e18);
        token1.mint(multisig, 1_000e18);
        vm.startPrank(multisig);
        token0.approve(address(controller), type(uint256).max);
        token1.approve(address(controller), type(uint256).max);
        uint256 shares = controller.bootstrap(key, 100e18, 200e18);
        vm.stopPrank();

        assertEq(shares, 1_000e18);
        assertEq(mockHook.bootstrapCalls(), 1);
        assertEq(mockHook.lastBootstrapAmount0(), 100e18);
        assertEq(mockHook.lastBootstrapAmount1(), 200e18);
        assertEq(ERC20(Currency.unwrap(key.currency0)).balanceOf(address(mockHook)), 100e18);
        assertEq(ERC20(Currency.unwrap(key.currency1)).balanceOf(address(mockHook)), 200e18);
    }

    function test_bootstrapAutoRecordsBasisSoImmediateHarvestIsNoOp() public {
        mockHook.setSharesOf(1_000e18);
        mockHook.setPreviewWithdraw(100e18, 200e18);

        token0.mint(multisig, 1_000e18);
        token1.mint(multisig, 1_000e18);
        vm.startPrank(multisig);
        token0.approve(address(controller), type(uint256).max);
        token1.approve(address(controller), type(uint256).max);
        controller.bootstrap(key, 100e18, 200e18);
        vm.stopPrank();

        (uint256 b0, uint256 b1) = controller.basis(key.toId());
        assertEq(b0, 100e18);
        assertEq(b1, 200e18);

        vm.prank(multisig);
        controller.harvest(key, 0, 0, block.timestamp);
        assertEq(mockHook.removeLiquidityCalls(), 0, "immediate post-bootstrap harvest must no-op");
    }

    // ── Constructor invariants ──────────────────────────────────────────────

    function test_skimCapEnforced() public {
        vm.expectRevert(OperatorControllerV2.SkimTooHigh.selector);
        new OperatorControllerV2(multisig, address(mockHook), address(allowlist), address(stakingVault), 2001);
    }

    function test_skimCapBoundaryOk() public {
        OperatorControllerV2 c =
            new OperatorControllerV2(multisig, address(mockHook), address(allowlist), address(stakingVault), 2000);
        assertEq(c.skimBps(), 2000);
    }

    // ── setSkimBps ───────────────────────────────────────────────────────────

    function test_ownerCanSetSkimBpsWithinCap() public {
        vm.expectEmit(true, true, true, true);
        emit OperatorControllerV2.SkimBpsSet(1500);
        vm.prank(multisig);
        controller.setSkimBps(1500);
        assertEq(controller.skimBps(), 1500);
    }

    function test_setSkimBpsAboveCapReverts() public {
        vm.prank(multisig);
        vm.expectRevert(OperatorControllerV2.SkimTooHigh.selector);
        controller.setSkimBps(2001);
    }

    function test_setSkimBpsNonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        controller.setSkimBps(1000);
    }
}
