// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DecStableCoin} from "../../src/DecStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DscEngineTest is Test {
    DeployDsc deployer;
    DecStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address wbtc;
    address public USER = makeAddr("user");

    modifier depositCollateral(uint256 amount) {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), amount);
        dscEngine.depositCollateral(weth, amount);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, dscEngine, config) = deployer.run();
        (
            wethUsdPriceFeed,
            wbtcUsdPriceFeed,
            weth,
            wbtc,
        ) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, 10 ether);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfTokenLengthDoesNotMatchPriceFeeds() public {
        // Create array of 2 tokens (WETH and WBTC)
        address[] memory tokens = new address[](2);
        tokens[0] = weth;
        tokens[1] = wbtc;

        // Create array with only 1 price feed (mismatch with tokens array)
        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = wethUsdPriceFeed;

        // Should revert since tokens array length (2) != price feeds array length (1)
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokens, priceFeeds, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              GETTER TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100e18; // $100
        // $100 / $2000 per ETH = 0.05 ETH
        uint256 expectedWeth = 0.05e18;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
                        depositCollateral TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        // Approve the DSC engine contract to spend 0 WETH tokens on behalf of the user
        // This line isn't actually needed since we're testing depositing 0 collateral
        ERC20Mock(weth).approve(address(dscEngine), 1e18);
        
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfTokenNotAllowed() public {
        // Create a mock token that isn't registered with the DSC engine
        ERC20Mock invalidToken = new ERC20Mock();
        
        vm.startPrank(USER);
        invalidToken.approve(address(dscEngine), 1e18);
        
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(invalidToken)));
        dscEngine.depositCollateral(address(invalidToken), 1e18);
        vm.stopPrank();
    }
    
    function testCollateralDepositedAmountIsAccurate() public depositCollateral(10 ether) {
        uint256 amountCollateral = 10 ether;
        uint256 depositedAmount = dscEngine.getCollateralDeposited(USER, weth);
        assertEq(depositedAmount, amountCollateral);
    }

    /*//////////////////////////////////////////////////////////////
                           REDEEM COLLATERAL
    //////////////////////////////////////////////////////////////*/

    function testCanRedeemCollateralWithGoodHealthFactor() public depositCollateral(10 ether) {
        // Setup: Deposit excess collateral and mint some DSC
        uint256 amountCollateral = 10e18; // 10 ETH @ $2000 = $20,000
        uint256 amountToMint = 100e18; // 100 DSC, way under-utilizing the collateral
        
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        // Try to redeem 9.9 ETH ($19,800 worth)
        // This should succeed because:
        // - Remaining collateral = 0.1 ETH ($200)
        // - DSC minted = $100
        // - Required collateral = $100 * 2 = $200 (with 50% liquidation threshold)
        // - Health factor after = ($200 * 0.5) / $100 = 1 (exactly at the threshold)
        uint256 redeemAmount = 9.9e18;
        dscEngine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        // Verify collateral was actually redeemed
        uint256 remainingCollateral = dscEngine.getCollateralDeposited(USER, weth);
        assertEq(remainingCollateral, amountCollateral - redeemAmount);

        // Verify WETH was actually returned to user
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, redeemAmount);

        // Verify health factor is exactly 1 (or very close due to potential rounding)
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assertApproxEqRel(healthFactor, 1e18, 1e15); // Allow 0.1% deviation
    }

    function testRevertsIfRedeemCollateralBreaksHealthFactor() public depositCollateral(10 ether) {
        uint256 amountCollateral = 10e18; // 10 ETH @ $2000 = $20,000
        uint256 amountToMint = 100e18; // 100 DSC

        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        // Try to redeem too much collateral
        // This should revert because:
        // - Trying to redeem 9.95 ETH ($19,900)
        // - Would leave only 0.05 ETH ($100) as collateral
        // - With $100 DSC minted, need at least $200 in collateral (50% threshold)
        uint256 redeemAmount = 9.95e18;
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0.5e18));
        dscEngine.redeemCollateral(weth, redeemAmount);
        vm.stopPrank();

        // Verify collateral amount remains unchanged after failed redemption
        uint256 remainingCollateral = dscEngine.getCollateralDeposited(USER, weth);
        assertEq(remainingCollateral, amountCollateral);
    }

    /*//////////////////////////////////////////////////////////////
                               mintDsc TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfMintDscWithoutCollateral() public {
        // User never deposits any collateral, just tries to mint DSC directly
        vm.startPrank(USER);
        // The 0 represents the health factor when there is no collateral (0 collateral = 0 health factor)
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0)); 
        dscEngine.mintDsc(1e18); // Try to mint 1 DSC without any collateral
        vm.stopPrank();
    }

    function testRevertsIfMintDscWithInsufficientCollateral() public {
        // Setup: Deposit small amount of collateral
        vm.startPrank(USER);
        uint256 amountCollateral = 1e18; // 1 ETH @ $2000 = $2000
        uint256 amountToMint = 1001e18; // $1001 DSC
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);

        // Try to mint more DSC than collateral value allows
        // 1 ETH = $2000, with 50% liquidation threshold = $1000 collateral value
        // Minting $1001 DSC would give health factor of: ($1000 * 1e18) / $1001 = 0.999000999000999e18
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0.999000999000999e18));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testMintedDscAmountIsAccurate() public depositCollateral(10 ether) {
        uint256 amountToMint = 100e18; // 100 DSC

        // Mint DSC
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();

        // Get amount of DSC minted by calling public getter function
        uint256 userDscMinted = dsc.balanceOf(USER);
        assertEq(userDscMinted, amountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN DSC TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfBurnMoreThanUserHas() public depositCollateral (10 ether) {
        uint256 amountToMint = 100e18; // 100 DSC

        // Setup: Deposit collateral and mint some DSC first
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        // Try to burn more than minted
        uint256 amountToBurn = amountToMint + 1; // 101 DSC
        vm.expectRevert();
        // vm.expectRevert(abi.encodeWithSelector(DecStableCoin.DecStableCoin__InsufficientBalance.selector, amountToMint, amountToBurn));
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testDscMintedStateIsAccurate() public depositCollateral(10 ether) {
        uint256 amountToMint = 100e18; // 100 DSC

        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);

        // Get amount of DSC minted by calling public getter function
        uint256 userDscMinted = dscEngine.getDscMinted(USER);
        assertEq(userDscMinted, amountToMint);

        // Burn some DSC
        uint256 amountToBurn = 50e18; // 50 DSC
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);

        // Check state is updated correctly
        userDscMinted = dscEngine.getDscMinted(USER);
        assertEq(userDscMinted, amountToMint - amountToBurn);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/
    function testLiquidationRevertsIfHealthFactorOk() public depositCollateral(10 ether) {
        // Setup: Deposit collateral and mint DSC, keeping health factor healthy
        uint256 amountToMint = 100e18; // 100 DSC, well below max for 10 ETH
        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();

        // Try to liquidate a healthy position
        address liquidator = makeAddr("LIQUIDATOR");
        vm.startPrank(liquidator);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    function testCanLiquidateUserWithPoorHealthFactor() public {
        
    }

    function testLiquidatorGetsCollateralAndBonus() public {
        // Setup:
        // 1. User deposits collateral (ETH)
        // 2. User mints DSC to near max
        // 3. ETH price drops, making user's position unhealthy
        
        // Liquidation:
        // 1. Liquidator has enough DSC
        // 2. Liquidator calls liquidate()
        
        // Checks:
        // 1. Verify liquidator received correct amount of collateral
        // 2. Verify liquidator received bonus amount
        // 3. Verify user's remaining collateral is correct
        // 4. Verify DSC burned matches amount repaid
    }

}
