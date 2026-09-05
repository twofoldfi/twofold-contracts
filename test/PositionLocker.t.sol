// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionLocker} from "../src/PositionLocker.sol";

contract MockPosm {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => PoolKey) internal keys;
    mapping(uint256 => uint128) public getPositionLiquidity;

    bytes public lastUnlockData;
    uint256 public lastDeadline;
    uint256 public modifyCalls;

    function mint(address to, uint256 tokenId, PoolKey memory key, uint128 liquidity) external {
        ownerOf[tokenId] = to;
        keys[tokenId] = key;
        getPositionLiquidity[tokenId] = liquidity;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        if (to.code.length > 0) {
            bytes4 sel = PositionLocker(to).onERC721Received(msg.sender, from, tokenId, "");
            require(sel == PositionLocker.onERC721Received.selector, "unsafe recipient");
        }
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256) {
        return (keys[tokenId], 0);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        uint256 tokenId = abi.decode(_firstParam(unlockData), (uint256));
        require(ownerOf[tokenId] == msg.sender, "not approved");
        require(getPositionLiquidity[tokenId] > 0, "CannotUpdateEmptyPosition");
        lastUnlockData = unlockData;
        lastDeadline = deadline;
        modifyCalls++;
    }

    function _firstParam(bytes calldata unlockData) internal pure returns (bytes memory) {
        (, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        return params[0];
    }
}

contract PositionLockerTest is Test {
    PositionLocker locker;
    MockPosm posm;
    address owner = makeAddr("owner");
    address rando = makeAddr("rando");
    address feeRecipient = makeAddr("feeRecipient");
    address tokenA = makeAddr("tokenA");
    address tokenB = makeAddr("tokenB");
    uint256 constant ID = 1076283;

    function setUp() public {
        posm = new MockPosm();
        locker = new PositionLocker(address(posm), owner, feeRecipient);
        posm.mint(owner, ID, _key(), 1e18);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(tokenA),
            currency1: Currency.wrap(tokenB),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _lock() internal {
        vm.prank(owner);
        posm.safeTransferFrom(owner, address(locker), ID);
    }

    // ─── construction ───

    function test_constructorRejectsZeroFeeRecipient() public {
        vm.expectRevert(PositionLocker.ZeroRecipient.selector);
        new PositionLocker(address(posm), owner, address(0));
    }

    function test_constructorRejectsSelfFeeRecipient() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(PositionLocker.SelfRecipient.selector);
        new PositionLocker(address(posm), owner, predicted);
    }

    // ─── locking ───

    function test_safeTransferFromOwnerRegistersPosition() public {
        vm.expectEmit(true, false, false, true);
        emit PositionLocker.PositionLocked(ID);
        _lock();
        assertEq(posm.ownerOf(ID), address(locker));
        assertEq(locker.lockedCount(), 1);
        assertEq(locker.lockedIds(0), ID);
    }

    function test_onERC721ReceivedRejectsNonPosm() public {
        vm.prank(rando);
        vm.expectRevert(PositionLocker.NotPositionManager.selector);
        locker.onERC721Received(rando, owner, ID, "");
    }

    function test_transferFromNonOwnerIsRejected() public {
        posm.mint(rando, 999, _key(), 0);
        vm.prank(rando);
        vm.expectRevert(PositionLocker.NotFromOwner.selector);
        posm.safeTransferFrom(rando, address(locker), 999);
        assertEq(locker.lockedCount(), 0);
    }

    // ─── permanence: no exit path exists ───

    function test_noFunctionMovesTheNftOut() public {
        _lock();
        locker.claim(ID);
        assertEq(posm.ownerOf(ID), address(locker));
    }

    // ─── claiming (permissionless, fixed recipient) ───

    function test_claimEncodesZeroDecreaseAndTakePairToFeeRecipient() public {
        _lock();
        vm.prank(rando);
        vm.expectEmit(true, true, false, true);
        emit PositionLocker.FeesClaimed(ID, feeRecipient);
        locker.claim(ID);

        assertEq(posm.modifyCalls(), 1);
        assertEq(posm.lastDeadline(), block.timestamp);
        (bytes memory actions, bytes[] memory params) =
            abi.decode(posm.lastUnlockData(), (bytes, bytes[]));
        assertEq(actions, hex"0111"); // DECREASE_LIQUIDITY, TAKE_PAIR
        assertEq(params.length, 2);
        (uint256 tokenId, uint256 liq, uint128 min0, uint128 min1,) =
            abi.decode(params[0], (uint256, uint256, uint128, uint128, bytes));
        assertEq(tokenId, ID);
        assertEq(liq, 0);
        assertEq(min0, 0);
        assertEq(min1, 0);
        (Currency c0, Currency c1, address to) = abi.decode(params[1], (Currency, Currency, address));
        assertEq(Currency.unwrap(c0), tokenA);
        assertEq(Currency.unwrap(c1), tokenB);
        assertEq(to, feeRecipient);
    }

    function test_claimByRandoStillPaysFeeRecipientOnly() public {
        _lock();
        vm.prank(rando);
        locker.claim(ID);
        (, bytes[] memory params) = abi.decode(posm.lastUnlockData(), (bytes, bytes[]));
        (,, address to) = abi.decode(params[1], (Currency, Currency, address));
        assertEq(to, feeRecipient);
    }

    function test_claimOnUnheldPositionReverts() public {
        posm.mint(owner, 42, _key(), 1e18);
        vm.expectRevert("not approved");
        locker.claim(42);
    }

    function test_claimAllIsPermissionlessAndClaimsEverything() public {
        _lock();
        posm.mint(owner, 43, _key(), 5);
        vm.prank(owner);
        posm.safeTransferFrom(owner, address(locker), 43);
        assertEq(locker.lockedCount(), 2);
        vm.prank(rando);
        locker.claimAll();
        assertEq(posm.modifyCalls(), 2);
    }

    function test_claimAllSkipsZeroLiquidityPositionInsteadOfReverting() public {
        _lock();
        posm.mint(owner, 44, _key(), 0);
        vm.prank(owner);
        posm.safeTransferFrom(owner, address(locker), 44);
        assertEq(locker.lockedCount(), 2);
        locker.claimAll();
        assertEq(posm.modifyCalls(), 1);
        (, bytes[] memory params) = abi.decode(posm.lastUnlockData(), (bytes, bytes[]));
        assertEq(abi.decode(params[0], (uint256)), ID);
    }

    // ─── fee recipient management ───

    function test_ownerCanSetFeeRecipient() public {
        address next = makeAddr("next");
        vm.expectEmit(true, false, false, true);
        emit PositionLocker.FeeRecipientSet(next);
        vm.prank(owner);
        locker.setFeeRecipient(next);
        assertEq(locker.feeRecipient(), next);
        _lock();
        locker.claim(ID);
        (, bytes[] memory params) = abi.decode(posm.lastUnlockData(), (bytes, bytes[]));
        (,, address to) = abi.decode(params[1], (Currency, Currency, address));
        assertEq(to, next);
    }

    function test_nonOwnerCannotSetFeeRecipient() public {
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        locker.setFeeRecipient(rando);
    }

    function test_cannotSetZeroFeeRecipient() public {
        vm.prank(owner);
        vm.expectRevert(PositionLocker.ZeroRecipient.selector);
        locker.setFeeRecipient(address(0));
    }

    function test_cannotSetSelfAsFeeRecipient() public {
        vm.prank(owner);
        vm.expectRevert(PositionLocker.SelfRecipient.selector);
        locker.setFeeRecipient(address(locker));
    }

    // ─── ownership ───

    function test_renounceOwnershipIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(PositionLocker.RenounceDisabled.selector);
        locker.renounceOwnership();
        assertEq(locker.owner(), owner);
        // the gate this protects: with owner() zeroed, a direct mint
        // (from == address(0)) would register junk positions
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        locker.renounceOwnership();
    }

    function test_twoStepOwnershipTransfer() public {
        vm.prank(owner);
        locker.transferOwnership(rando);
        assertEq(locker.owner(), owner);
        vm.prank(rando);
        locker.acceptOwnership();
        assertEq(locker.owner(), rando);
    }
}
