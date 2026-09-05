// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
// Halmos: PoolZapper share-ledger conservation. The hook/manager legs are
// mocked to isolate the ledger arithmetic; the swap/deposit plumbing is
// covered by the fork suite. Properties: zapOut can never burn more than the
// caller was credited, credits/burns move the ledger by exactly the stated
// amount, and one user's burn cannot touch another user's entry.
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolZapper, IDualPoolHookZap, IWETH9} from "../../src/PoolZapper.sol";

contract HalmosMockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

contract HalmosMockHook {
    HalmosMockToken public t0;
    HalmosMockToken public t1;
    constructor(HalmosMockToken _t0, HalmosMockToken _t1) { t0 = _t0; t1 = _t1; }
    function addLiquidity(PoolKey calldata, uint256 shares, uint256 max0, uint256 max1, uint256)
        external returns (uint256, uint256)
    {
        t0.transferFrom(msg.sender, address(this), max0);
        t1.transferFrom(msg.sender, address(this), max1);
        shares;
        return (max0, max1);
    }
    function removeLiquidity(PoolKey calldata, uint256 shares, uint256 min0, uint256 min1, uint256)
        external returns (uint256, uint256)
    {
        shares;
        t0.transfer(msg.sender, min0);
        t1.transfer(msg.sender, min1);
        return (min0, min1);
    }
}

contract PoolZapperLedgerTest is Test {
    using PoolIdLibrary for PoolKey;

    PoolZapper zapper;
    HalmosMockToken tok0;
    HalmosMockToken tok1;
    HalmosMockHook hook;
    PoolKey key;

    function setUp() public {
        tok0 = new HalmosMockToken();
        tok1 = new HalmosMockToken();
        if (address(tok1) < address(tok0)) (tok0, tok1) = (tok1, tok0);
        hook = new HalmosMockHook(tok0, tok1);
        zapper = new PoolZapper(
            IPoolManager(address(0xDEAD)),
            IDualPoolHookZap(address(hook)),
            IWETH9(address(new HalmosMockToken())),
            IERC20(address(tok1))
        );
        key = PoolKey(
            Currency.wrap(address(tok0)), Currency.wrap(address(tok1)), 3000, 60, IHooks(address(hook))
        );
    }

    function check_zapOut_neverExceedsCredit(
        address alice, address bob, uint256 credA, uint256 credB, uint256 burn
    ) public {
        vm.assume(alice != bob);
        vm.assume(alice != address(0) && bob != address(0));
        bytes32 pid = PoolId.unwrap(key.toId());
        vm.assume(credA < type(uint128).max && credB < type(uint128).max);

        tok1.mint(alice, credA + credB);
        vm.startPrank(alice);
        tok1.approve(address(zapper), credA);
        if (credA > 0) zapper.zapInUSDG(key, key, credA, 0, 0, credA, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.startPrank(bob);
        tok1.mint(bob, credB);
        tok1.approve(address(zapper), credB);
        if (credB > 0) zapper.zapInUSDG(key, key, credB, 0, 0, credB, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();

        uint256 aBefore = zapper.sharesOf(pid, alice);
        uint256 bBefore = zapper.sharesOf(pid, bob);
        assertEq(aBefore, credA);
        assertEq(bBefore, credB);

        vm.prank(alice);
        try zapper.zapOut(key, burn, 0, 0, block.timestamp) {
            assert(burn > 0 && burn <= aBefore);
            assertEq(zapper.sharesOf(pid, alice), aBefore - burn);
        } catch {
            assert(burn == 0 || burn > aBefore);
        }
        assertEq(zapper.sharesOf(pid, bob), bBefore);
    }
}
