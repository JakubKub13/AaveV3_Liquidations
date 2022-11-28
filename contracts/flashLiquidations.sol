// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IFlashLoanSimpleReceiver} from "@aave/core-v3/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import {AaveProtocolDataProvider} from "@aave/core-v3/contracts/misc/AaveProtocolDataProvider.sol";
import {AaveOracle} from "@aave/core-v3/contracts/misc/AaveOracle.sol";
import {FlashLoanSimpleReceiverBase} from "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IERC20} from "@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

import "hardhat/console.sol";

contract FlashLiquidations is FlashLoanSimpleReceiverBase, Ownable {
    /// Parameters used for _liquidateAndSwap and final transfer of funds to owner
    struct LiquidationParams {
        address collateralAsset;
        address borrowedAsset;
        address user;
        uint256 debtToCover;
        uint24 poolFee1;
        uint24 poolFee2;
        address pathToken;
        bool usePath;
    }

    ///Parameters used for liquidation and swap logic
    struct LiquidationCallLocalVars {
        uint256 initFlashBorrowedBalance;
        uint256 diffFlashBorrowedBalance;
        uint256 initCollateralBalance;
        uint256 diffCollateralBalance;
        uint256 flashLoanDebt;
        uint256 soldAmount;
        uint256 remainingTokens;
        uint256 borrowedAssetLeftovers;
    }

    ISwapRouter public immutable swapRouter;

    constructor(IPoolAddressesProvider _addressProvider, ISwapRouter _swapRouter) FlashLoanSimpleReceiverBase(_addressProvider) {
        swapRouter = ISwapRouter(_swapRouter);
    }

    /**
     * @notice This function executes the operation after receiving assets in form of Flash loan
     * @dev Must be ensured that contract can return debt + premium
     * @param asset -> the address of flash-borrowed asset
     * @param amount -> the amount of the flash-borrowed asset
     * @param premium -> fee for flashloan
     * @param params -> The byte-encoded params passed when init flashloan
     * @return true if execution of operation seccess, else false
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        require(msg.sender == address(POOL), "FlashLiquidations: Caller must be lending pool");

        LiquidationParams memory decodedParams = _decodeParams(params);

        require(asset == decodedParams.borrowedAsset, "FlashLiquidations: Wrong params passed - asset not the same");
        console.log("Trying to liquidate and swap");
        _liquidateAndSwap(
            decodedParams.collateralAsset,
            decodedParams.borrowedAsset,
            decodedParams.user,
            decodedParams.debtToCover,
            decodedParams.poolFee1,
            decodedParams.poolFee2,
            decodedParams.pathToken,
            decodedParams.usePath,
            amount,
            premium
        );
        return true;
    }

    /**
     * @notice This func decodes the params obtained from myFlashLoan function
     * @param params -> params encoded in bytes form passed when initialize the flashloan
     * @return LiquidationParams memory struct
     */
    function _decodeParams(bytes memory params) internal pure returns (LiquidationParams memory) {
        (
            address collateralAsset,
            address borrowedAsset,
            address user,
            uint256 debtToCover,
            uint24 poolFee1,
            uint24 poolFee2,
            address pathToken,
            bool usePath
        ) = abi.decode(params, (address, address, address, uint256, uint24, uint24, address, bool));

        return LiquidationParams(
            collateralAsset,
            borrowedAsset,
            user,
            debtToCover,
            poolFee1,
            poolFee2,
            pathToken,
            usePath
        );
    }


}