// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecStableCoin} from "../src/DecStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDsc is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (DecStableCoin, DSCEngine, HelperConfig) {
        // Before broadcast -> not a real tx
        HelperConfig config = new HelperConfig();
        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed, 
            address weth,
            address wbtc,
        ) = config.activeNetworkConfig();

        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        // After broadcast -> real tx
        vm.startBroadcast();
        DecStableCoin dsc = new DecStableCoin();
        DSCEngine engine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );

        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (dsc, engine, config);
    }
}
