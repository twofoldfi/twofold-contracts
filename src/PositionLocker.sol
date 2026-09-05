// ╔══════════════════════════════════════════════════════════════════════╗
// ║  TWOFOLD                                                             ║
// ║  PositionLocker                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IPositionManagerLike {
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

contract PositionLocker is Ownable2Step {
    uint8 private constant ACTION_DECREASE_LIQUIDITY = 0x01;
    uint8 private constant ACTION_TAKE_PAIR = 0x11;

    IPositionManagerLike public immutable positionManager;
    address public feeRecipient;
    uint256[] public lockedIds;

    event PositionLocked(uint256 indexed tokenId);
    event FeeRecipientSet(address indexed recipient);
    event FeesClaimed(uint256 indexed tokenId, address indexed recipient);

    error NotPositionManager();
    error NotFromOwner();
    error ZeroRecipient();
    error SelfRecipient();
    error RenounceDisabled();

    constructor(address positionManager_, address owner_, address feeRecipient_) Ownable(owner_) {
        if (feeRecipient_ == address(0)) revert ZeroRecipient();
        if (feeRecipient_ == address(this)) revert SelfRecipient();
        positionManager = IPositionManagerLike(positionManager_);
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function lockedCount() external view returns (uint256) {
        return lockedIds.length;
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroRecipient();
        if (recipient == address(this)) revert SelfRecipient();
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        if (from != owner()) revert NotFromOwner();
        lockedIds.push(tokenId);
        emit PositionLocked(tokenId);
        return this.onERC721Received.selector;
    }

    function claim(uint256 tokenId) public {
        address recipient = feeRecipient;
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId);
        bytes memory actions = abi.encodePacked(ACTION_DECREASE_LIQUIDITY, ACTION_TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        emit FeesClaimed(tokenId, recipient);
    }

    function claimAll() external {
        uint256 n = lockedIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = lockedIds[i];
            if (positionManager.getPositionLiquidity(tokenId) == 0) continue;
            claim(tokenId);
        }
    }
}
