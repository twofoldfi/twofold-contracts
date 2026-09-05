// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionLocker} from "../../src/PositionLocker.sol";

/// @notice Halmos symbolic properties over PositionLocker. Claiming is
///         deliberately permissionless (fees can only ever go to the stored
///         feeRecipient), so the security story is three gates: only the
///         owner can redirect fees, only the PositionManager can deliver a
///         lock, and only NFTs sent BY the owner register. Proven for all
///         callers/inputs, not sampled.
contract PositionLockerAuthTest is Test {
    PositionLocker locker;
    address owner = address(0xA11CE);
    address recipient = address(0xFEE);
    address posm = address(0xBEEF);

    function setUp() public {
        locker = new PositionLocker(posm, owner, recipient);
    }

    /// @notice Property: no caller other than the owner can change feeRecipient,
    ///         and the recipient is untouched by the failed attempt.
    function check_nonOwnerCannotSetFeeRecipient(address caller, address next) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        (bool ok,) = address(locker).call(abi.encodeCall(PositionLocker.setFeeRecipient, (next)));
        assert(!ok);
        assert(locker.feeRecipient() == recipient);
    }

    /// @notice Property: the owner can never set feeRecipient to zero or to the
    ///         locker itself (fees into either are unrecoverable - no sweep exists).
    function check_feeRecipientNeverZeroOrSelf(address next) public {
        vm.prank(owner);
        (bool ok,) = address(locker).call(abi.encodeCall(PositionLocker.setFeeRecipient, (next)));
        assert(locker.feeRecipient() != address(0));
        assert(locker.feeRecipient() != address(locker));
        if (next == address(0) || next == address(locker)) assert(!ok);
    }

    /// @notice Property: no caller other than the PositionManager can register a locked id.
    function check_nonPosmCannotRegister(address caller, address from, uint256 tokenId) public {
        vm.assume(caller != posm);
        vm.prank(caller);
        (bool ok,) = address(locker).call(
            abi.encodeCall(PositionLocker.onERC721Received, (caller, from, tokenId, ""))
        );
        assert(!ok);
        assert(locker.lockedCount() == 0);
    }

    /// @notice Property about STATE, not caller: no call to any ownership
    ///         function leaves owner() zero - the from-owner registration gate
    ///         compares against owner(), and ERC721 mints arrive with
    ///         from == address(0), so a zeroed owner would open registration
    ///         to anyone. renounceOwnership is disabled for exactly this.
    function check_ownerNeverBecomesZero(address caller, bytes4 sel, address arg) public {
        vm.assume(caller != address(0)); // no real tx has a zero sender
        vm.assume(
            sel == PositionLocker.renounceOwnership.selector
                || sel == bytes4(keccak256("transferOwnership(address)"))
                || sel == bytes4(keccak256("acceptOwnership()"))
        );
        vm.prank(caller);
        address(locker).call(abi.encodePacked(sel, abi.encode(arg)));
        assert(locker.owner() != address(0));
    }

    /// @notice Property: even the PositionManager cannot register an NFT that was
    ///         not sent by the locker owner (the anti-griefing gate).
    function check_posmCannotRegisterFromNonOwner(address from, uint256 tokenId) public {
        vm.assume(from != owner);
        vm.prank(posm);
        (bool ok,) = address(locker).call(
            abi.encodeCall(PositionLocker.onERC721Received, (from, from, tokenId, ""))
        );
        assert(!ok);
        assert(locker.lockedCount() == 0);
    }
}
