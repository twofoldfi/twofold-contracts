// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Registry} from "../src/Registry.sol";
import {VaultAllowlist} from "../src/VaultAllowlist.sol";

contract FakeFactory {
    mapping(address => bool) public from;
    function set(address a, bool b) external { from[a] = b; }
    function isFromFactory(address a) external view returns (bool) { return from[a]; }
}

contract RegistryTest is Test {
    Registry reg;
    VaultAllowlist list;
    FakeFactory fac;
    address owner = makeAddr("owner");
    address hook = makeAddr("hook");
    address v0 = makeAddr("vault0");
    address v1 = makeAddr("vault1");

    function setUp() public {
        list = new VaultAllowlist(owner);
        fac = new FakeFactory();
        reg = new Registry(owner, address(fac), address(list));
    }

    function _listing(bytes32 id) internal returns (Registry.PoolListing memory) {
        return Registry.PoolListing({
            hook: hook, poolId: id,
            currency0: makeAddr("usdg"), currency1: makeAddr("usdc"),
            fee: 100, vault0: v0, vault1: v1,
            mode: Registry.OperatorMode.ProtocolOperated,
            verified: true, // must be ignored/recomputed
            active: true
        });
    }

    function test_verifiedComputedNotTrusted() public {
        // hook NOT from factory, vaults NOT allowed → verified must be false
        vm.prank(owner);
        reg.listPool(_listing(bytes32(uint256(1))));
        assertFalse(reg.getPool(bytes32(uint256(1))).verified);
    }

    // The stored `verified` field is never observable through getPool, which
    // recomputes it live on every read. The ONLY surface that exposes what
    // listPool actually wrote is the PoolListed event, which indexers and the
    // site activity feed consume. Without these two the write path can be
    // hardcoded to `true` and the whole suite stays green (mutation M13,
    // SURVIVOR on 2026-08-20).
    event PoolListed(bytes32 indexed poolId, address indexed hook, bool verified);

    function test_listedEventCarriesVerifiedFalseWhenChecksFail() public {
        vm.expectEmit(true, true, false, true);
        emit PoolListed(bytes32(uint256(11)), hook, false);
        vm.prank(owner);
        reg.listPool(_listing(bytes32(uint256(11))));
    }

    function test_listedEventCarriesVerifiedTrueWhenChecksPass() public {
        fac.set(hook, true);
        vm.startPrank(owner);
        list.setAllowed(v0, true);
        list.setAllowed(v1, true);
        vm.expectEmit(true, true, false, true);
        emit PoolListed(bytes32(uint256(12)), hook, true);
        reg.listPool(_listing(bytes32(uint256(12))));
        vm.stopPrank();
    }

    function test_verifiedWhenFactoryAndVaultsPass() public {
        fac.set(hook, true);
        vm.startPrank(owner);
        list.setAllowed(v0, true);
        list.setAllowed(v1, true);
        reg.listPool(_listing(bytes32(uint256(2))));
        vm.stopPrank();
        assertTrue(reg.getPool(bytes32(uint256(2))).verified);
    }

    function test_zeroVaultCountsAsAllowed() public {
        fac.set(hook, true);
        vm.startPrank(owner);
        list.setAllowed(v0, true);
        Registry.PoolListing memory l = _listing(bytes32(uint256(3)));
        l.vault1 = address(0);
        reg.listPool(l);
        vm.stopPrank();
        assertTrue(reg.getPool(bytes32(uint256(3))).verified);
    }

    function test_onlyOwnerLists() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        reg.listPool(_listing(bytes32(uint256(4))));
    }

    function test_onlyOwnerSetsActive() public {
        vm.prank(owner);
        reg.listPool(_listing(bytes32(uint256(20))));
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        reg.setActive(bytes32(uint256(20)), false);
    }

    function test_duplicateIdReverts() public {
        vm.startPrank(owner);
        reg.listPool(_listing(bytes32(uint256(5))));
        vm.expectRevert(Registry.AlreadyListed.selector);
        reg.listPool(_listing(bytes32(uint256(5))));
        vm.stopPrank();
    }

    function test_enumeration() public {
        vm.startPrank(owner);
        reg.listPool(_listing(bytes32(uint256(6))));
        reg.listPool(_listing(bytes32(uint256(7))));
        vm.stopPrank();
        assertEq(reg.allPoolIds().length, 2);
    }

    function test_verifiedDriftsFalseAfterVaultDeallowlisted() public {
        fac.set(hook, true);
        vm.startPrank(owner);
        list.setAllowed(v0, true);
        list.setAllowed(v1, true);
        reg.listPool(_listing(bytes32(uint256(9))));
        assertTrue(reg.getPool(bytes32(uint256(9))).verified);

        list.setAllowed(v0, false);
        vm.stopPrank();

        assertFalse(reg.getPool(bytes32(uint256(9))).verified);
    }

    function test_verifiedBecomesTrueAfterLateAllowlisting() public {
        fac.set(hook, true);
        vm.startPrank(owner);
        reg.listPool(_listing(bytes32(uint256(10))));
        assertFalse(reg.getPool(bytes32(uint256(10))).verified);

        list.setAllowed(v0, true);
        list.setAllowed(v1, true);
        vm.stopPrank();

        assertTrue(reg.getPool(bytes32(uint256(10))).verified);
    }

    function test_zeroHookReverts() public {
        vm.startPrank(owner);
        Registry.PoolListing memory l = _listing(bytes32(uint256(8)));
        l.hook = address(0);
        vm.expectRevert(Registry.ZeroHook.selector);
        reg.listPool(l);
        vm.stopPrank();
    }
}
