// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD6} from "./MockUSD6.sol";

/// @notice Feeless ERC-4626 vault over a MockUSD6 asset, for Task 7's integration test.
///         Stock OZ ERC4626 has no entry/exit fee (previewDeposit == convertToShares,
///         previewRedeem == convertToAssets), satisfying DualPoolHook's `_requireFeelessVault`
///         probe. `simulateYield` donates directly to the vault's asset balance, raising the
///         share price for existing holders without minting new shares — a yield event.
contract MockERC4626 is ERC4626 {
    constructor(MockUSD6 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    /// @notice Simulate yield accrual by minting `amount` of the underlying asset directly to
    ///         this vault, without minting shares. Raises `convertToAssets` for existing shares.
    function simulateYield(uint256 amount) external {
        MockUSD6(asset()).mint(address(this), amount);
    }
}
