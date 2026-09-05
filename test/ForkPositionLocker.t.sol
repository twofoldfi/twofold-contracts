// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ═══════════════════════════════════════════════════════════════════════════
// End-to-end proof on a Robinhood Chain fork that PositionLocker can hold the
// LIVE TWO genesis position (tokenId 1076283) and still pull its accrued swap
// fees: deploy a locker owned by the real NFT owner, safeTransferFrom the
// real NFT in, have a RANDO trigger the permissionless claim, and assert the
// fees land on the stored feeRecipient while the position's liquidity is
// byte-identical to before. Also proves the permanence claim on the real
// PositionManager: the locker never approves anyone, so neither the locker
// owner nor anyone else can transfer the NFT back out.
//
// Needs an anvil fork of chain 4663 (FORK_RPC_8547, default localhost:8547);
// skips cleanly when absent, same as the other Fork*.t.sol suites.
// ═══════════════════════════════════════════════════════════════════════════

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionLocker} from "../src/PositionLocker.sol";

interface IPosmFull {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20Bal {
    function balanceOf(address) external view returns (uint256);
}

contract ForkPositionLockerTest is Test {
    IPosmFull internal constant POSM = IPosmFull(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    uint256 internal constant GENESIS_ID = 1076283;

    address recipient = makeAddr("recipient");
    address rando = makeAddr("rando");
    address nftOwner;
    PositionLocker locker;
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_8547", string("http://localhost:8547"));
        try vm.createSelectFork(rpc) {} catch {
            return;
        }
        forked = true;
        assertEq(block.chainid, 4663, "not on the Robinhood Chain fork");
        assertGt(address(POSM).code.length, 0, "real PositionManager missing on fork");
        nftOwner = POSM.ownerOf(GENESIS_ID);
        locker = new PositionLocker(address(POSM), nftOwner, recipient);
    }

    function _lockGenesis() internal {
        vm.prank(nftOwner);
        POSM.safeTransferFrom(nftOwner, address(locker), GENESIS_ID);
    }

    function test_lockRealGenesisAndRandoClaimsRealFeesToRecipient() public {
        if (!forked) return;
        _lockGenesis();
        assertEq(POSM.ownerOf(GENESIS_ID), address(locker));
        assertEq(locker.lockedCount(), 1);
        assertEq(locker.lockedIds(0), GENESIS_ID);

        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(GENESIS_ID);
        uint128 liqBefore = POSM.getPositionLiquidity(GENESIS_ID);
        assertGt(liqBefore, 0, "genesis position has no liquidity?");
        uint256 bal0Before = _balance(key.currency0, recipient);
        uint256 bal1Before = _balance(key.currency1, recipient);
        uint256 rando0Before = _balance(key.currency0, rando);

        vm.prank(rando);
        locker.claim(GENESIS_ID);

        uint256 got0 = _balance(key.currency0, recipient) - bal0Before;
        uint256 got1 = _balance(key.currency1, recipient) - bal1Before;
        emit log_named_uint("fees currency0", got0);
        emit log_named_uint("fees currency1", got1);
        assertTrue(got0 > 0 || got1 > 0, "no fees arrived");
        assertEq(_balance(key.currency0, rando), rando0Before, "caller pocketed fees");
        assertEq(POSM.getPositionLiquidity(GENESIS_ID), liqBefore, "liquidity moved");
        assertEq(POSM.ownerOf(GENESIS_ID), address(locker), "NFT left the locker");
    }

    function test_claimAllViaRandoAlsoWorks() public {
        if (!forked) return;
        _lockGenesis();
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(GENESIS_ID);
        uint256 bal0Before = _balance(key.currency0, recipient);
        vm.prank(rando);
        locker.claimAll();
        assertGt(_balance(key.currency0, recipient), bal0Before, "claimAll delivered nothing");
    }

    function test_secondClaimYieldsNothingNew() public {
        if (!forked) return;
        _lockGenesis();
        (PoolKey memory key,) = POSM.getPoolAndPositionInfo(GENESIS_ID);
        locker.claim(GENESIS_ID);
        uint256 bal0 = _balance(key.currency0, recipient);
        uint256 bal1 = _balance(key.currency1, recipient);
        locker.claim(GENESIS_ID);
        assertEq(_balance(key.currency0, recipient), bal0);
        assertEq(_balance(key.currency1, recipient), bal1);
    }

    function test_nobodyCanPullTheNftBackOut() public {
        if (!forked) return;
        _lockGenesis();

        vm.prank(nftOwner);
        vm.expectRevert();
        POSM.transferFrom(address(locker), nftOwner, GENESIS_ID);

        vm.prank(rando);
        vm.expectRevert();
        POSM.transferFrom(address(locker), rando, GENESIS_ID);

        assertEq(POSM.ownerOf(GENESIS_ID), address(locker));
    }

    function _balance(Currency c, address who) internal view returns (uint256) {
        return Currency.unwrap(c) == address(0) ? who.balance : IERC20Bal(Currency.unwrap(c)).balanceOf(who);
    }
}
