// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {DecStableCoin} from "../../../src/DecStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";

/**
 * @title Handler Contract for DSCEngine Invariant Tests
 * @notice This contract acts as a "handler" for invariant testing of the DSCEngine.
 * It provides controlled ways to interact with the DSCEngine during fuzz testing.
 * 
 * The handler:
 * 1. Bounds input parameters to reasonable ranges to avoid edge cases
 * 2. Manages test state like minting collateral tokens
 * 3. Provides helper functions for common testing flows
 * 4. Ensures interactions with DSCEngine maintain system invariants
 * 5. Handles price feed updates for collateral tokens
 * 
 * This allows for more focused and meaningful invariant testing compared to
 * completely random fuzzing of the DSCEngine directly.
 */
contract Handler is Test {
    DSCEngine dscEngine;
    DecStableCoin dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    uint256 public timesMintCalled = 0;
    address[] public usersWithCollateral;

    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 90000e8;
    uint8 public constant PRICE_FEED_DECIMALS = 8;

    constructor(DSCEngine _dscEngine, DecStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;
        
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = new MockV3Aggregator(
            PRICE_FEED_DECIMALS,
            ETH_USD_PRICE
        );
        btcUsdPriceFeed = new MockV3Aggregator(
            PRICE_FEED_DECIMALS,
            BTC_USD_PRICE
        );
    }

    // Deposit collateral before redeem.
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateralToken = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        collateralToken.mint(msg.sender, amountCollateral);
        vm.startPrank(msg.sender);
        collateralToken.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateralToken), amountCollateral);
        vm.stopPrank();
        _addUserToCollateralList(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateralToken = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = _getMaxCollateralToRedeem(msg.sender, collateralToken);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) return;

        vm.startPrank(msg.sender);
        dscEngine.redeemCollateral(address(collateralToken), amountCollateral);
        vm.stopPrank();
    }

    function mintDsc(uint256 amountToMint) public {
        if (usersWithCollateral.length == 0) return;
        address user = usersWithCollateral[uint256(keccak256(abi.encodePacked(block.timestamp))) % usersWithCollateral.length];
        uint256 maxDscToMint = _getMaxDscToMint(user);
        amountToMint = bound(amountToMint, 0, maxDscToMint);
        if (amountToMint == 0) return;
        vm.startPrank(user);
        dscEngine.mintDsc(amountToMint);
        timesMintCalled++;
        vm.stopPrank();
    }

    /**
     * @notice Updates the price of either ETH or BTC collateral
     * @param collateralSeed Used to determine which collateral to update (even = ETH, odd = BTC)
     * @param newPrice The new USD price to set for the collateral
     * @dev Uses MockV3Aggregator to update price feeds
     * @dev Price is converted from uint96 to int256 since Chainlink uses signed integers
     */
    function updateCollateralPrice(uint256 collateralSeed, uint96 newPrice) public {
        int256 newPriceInt = int256(uint256(newPrice));
        if (collateralSeed % 2 == 0) {
            ethUsdPriceFeed.updateAnswer(newPriceInt);
        } else {
            btcUsdPriceFeed.updateAnswer(newPriceInt);
        }
    }

    function getUsersWithCollateralCount() public view returns (uint256) {
        return usersWithCollateral.length;
    }

    /*//////////////////////////////////////////////////////////////
                      PRIVATE & INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    // Helper functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }

    function _addUserToCollateralList(address user) private {
        for (uint256 i = 0; i < usersWithCollateral.length; i++) {
            if (usersWithCollateral[i] == user) {
                return;
            }
        }
        usersWithCollateral.push(user);
    }

    function _getMaxDscToMint(address user) private view returns (uint256) {
        uint256 totalCollateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 dscMinted = dscEngine.getDscMinted(user);
        return ((totalCollateralValue * 50) / 100) - dscMinted;  // 50 is LIQUIDATION_THRESHOLD
    }

    function _getMaxCollateralToRedeem(address user, ERC20Mock collateralToken) private view returns (uint256) {
        uint256 collateralBalance = dscEngine.getCollateralDeposited(user, address(collateralToken));
        uint256 dscMinted = dscEngine.getDscMinted(user);
        if (dscMinted == 0) return collateralBalance;
        uint256 collateralValueInUsd = dscEngine.getUsdValue(address(collateralToken), collateralBalance);
        uint256 minCollateralValueRequired = (dscMinted * 100) / 50;  // 50 is LIQUIDATION_THRESHOLD
        if (collateralValueInUsd <= minCollateralValueRequired) return 0;
        uint256 excessCollateralValue = collateralValueInUsd - minCollateralValueRequired;
        return (excessCollateralValue * collateralBalance) / collateralValueInUsd;
    }
}
