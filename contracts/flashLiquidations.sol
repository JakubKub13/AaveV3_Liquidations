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
     * @notice Executes the operation of liquidating the debt position after it swaps collateral asset back to asset borrowed via flashloan
     * @dev Pool contract must be approved for operations
     * @param collateralAsset -> Address of asset received from the liquidation
     * @param borrowedAsset -> Address of the asset borrowed via flashloan
     * @param user -> address of the user being liquidated
     * @param debtToCover -> amount of the debt to be liauidated
     * @param poolFee1 -> fee connected to uniswap pool
     * @param poolFee2 -> fee connected to uniswap pool
     * @param pathToken -> token which in case needs to be swap between two other tokens from the uniswap pool
     * @param usePath -> decicion whether to use single or multihop uniswap swap
     * @param flashBorrowedAmount -> amount that was borrowed via flashloan
     * @param premium -> fee for taking out flashloan
     */
    function _liquidateAndSwap(
        address collateralAsset,
        address borrowedAsset,
        address user,
        uint256 debtToCover,
        uint24 poolFee1,
        uint24 poolFee2,
        address pathToken,
        bool usePath,
        uint256 flashBorrowedAmount,
        uint256 premium
    ) internal {
        // Approval for router to spend `amountInMaximum` of colateral
        // In prod the max amount should be spend based on oracles or other data sources to acheive better swap 
        LiquidationCallLocalVars memory variables;

        // Initial collateral balance
        variables.initCollateralBalance = IERC20(collateralAsset).balanceOf(address(this));
        console.log("Initial collateral balance", variables.initCollateralBalance);

        // Check whether the initial balance of tokens was borrowed
        if(collateralAsset != borrowedAsset) {
            variables.initFlashBorrowedBalance = IERC20(borrowedAsset).balanceOf(address(this));
            console.log("Initial flash Loan borrowed balance", variables.initFlashBorrowedBalance);
            variables.borrowedAssetLeftovers = variables.initFlashBorrowedBalance - flashBorrowedAmount;
            console.log("Borrowed asset leftovers", variables.borrowedAssetLeftovers);
        }

        // Calculate the amount which will be send back to Aave pool
        variables.flashLoanDebt = flashBorrowedAmount + premium;
        console.log("FlashLoan debt", variables.flashLoanDebt);
        console.log("Approving liquidation");

        // Approve the pool to liquidate debt position
        require(IERC20(borrowedAsset).approve(address(POOL), debtToCover), "FlashLiquidations: Error while approving");
        console.log("Liquidation in process");
        console.log(debtToCover);

        // Liquidating the debt possition
        POOL.liquidationCall(collateralAsset, borrowedAsset, user, debtToCover, false);
        console.log("Liquidated");

        // Compare initial collateral balance with collateral balance after liquidation
        uint256 collateralBalanceAfter = IERC20(collateralAsset).balanceOf(address(this));
        uint256 debtBalanceAfter = IERC20(borrowedAsset).balanceOf(address(this));
        console.log("Debt balance after", debtBalanceAfter);
        console.log("Collateral balance after", collateralBalanceAfter);
        variables.diffCollateralBalance = collateralBalanceAfter - variables.initCollateralBalance;
        console.log("Difference", variables.diffCollateralBalance);

        // Calculate the swap and necessary collateral tokens to repay flashLoan
        if(collateralAsset != borrowedAsset) {
            uint256 flashBorrowedAssetAfter = IERC20(borrowedAsset).balanceOf(address(this));
            console.log("Flash borrowed asset after", flashBorrowedAssetAfter);
            variables.diffFlashBorrowedBalance = flashBorrowedAssetAfter - variables.borrowedAssetLeftovers;
            console.log("Difference", variables.diffFlashBorrowedBalance);
            uint256 amountOut = variables.flashLoanDebt - variables.diffFlashBorrowedBalance;
            console.log("Debt tokens I want to receive", amountOut);
            console.log("Swapping collateral to debt");
            
            variables.soldAmount = swapExactOutputSingle(
                collateralAsset,
                borrowedAsset,
                amountOut,
                variables.diffCollateralBalance,
                poolFee1,
                poolFee2,
                pathToken,
                usePath
            );

            // Check for tokens to transfer to contract owner
            console.log("Remaining collateral");
            variables.remainingTokens = variables.diffCollateralBalance - variables.soldAmount;
            console.log("Error");
        } else {
            variables.remainingTokens = variables.diffCollateralBalance - premium;
        }

        // Approve for flash loan repayment
        IERC20(borrowedAsset).approve(address(POOL), variables.flashLoanDebt);  
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