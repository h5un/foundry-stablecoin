// What are our invariants?
// 1. The total supply of dsc should be less than the total value of the collateral
// 2. Getter functions should never revert

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../../script/DeployDsc.s.sol";
import {DSCEngine} from "../../../src/DSCEngine.sol";
import {DecStableCoin} from "../../../src/DecStableCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDsc deployer;
    DSCEngine dscEngine;
    DecStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(dscEngine));
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // Get the value of all collateral in the protocol
        // Compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        console.log("Total Supply: ", totalSupply);

        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 totalWethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 totalWbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);
        
        assert(totalWbtcValue + totalWethValue >= totalSupply);
        console.log("Times mint called: ", handler.timesMintCalled());
    }

    function invariant_gettersShouldNotRevert() public view {
        // All view functions should never revert
        // Try all getter functions with random inputs
        dscEngine.getAccountCollateralValue(msg.sender);
        dscEngine.getCollateralDeposited(msg.sender, weth);
        dscEngine.getCollateralDeposited(msg.sender, wbtc);
        dscEngine.getCollateralTokens();
        dscEngine.getDscMinted(msg.sender);
        dscEngine.getHealthFactor(msg.sender);
        dscEngine.getTokenAmountFromUsd(weth, 100);
        dscEngine.getTokenAmountFromUsd(wbtc, 100); 
        dscEngine.getUsdValue(weth, 100);
        dscEngine.getUsdValue(wbtc, 100);
    }
}
