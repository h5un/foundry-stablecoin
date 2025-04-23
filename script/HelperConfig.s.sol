// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed; // Price feed for ETH/USD
        address wbtcUsdPriceFeed; // Price feed for BTC/USD  
        address weth; // Wrapped ETH token address
        address wbtc; // Wrapped BTC token address
        uint256 deployerKey; // Private key used to deploy contracts on local networks
    }

    uint8 public constant DECIMALS = 8;
    int256 constant ETH_INITIAL_PRICE = 2000e8; // $2000 per ETH
    int256 constant BTC_INITIAL_PRICE = 90000e8; // $90000 per BTC

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            // Sepolia
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            // Mainnet
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            // Local network
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH / USD
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43, // BTC / USD
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81, // WETH
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063, // WBTC
            deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY") // Get private key from .env file
        });
    }

    function getMainnetEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            wethUsdPriceFeed: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, // ETH / USD
            wbtcUsdPriceFeed: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // BTC / USD
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
            wbtc: 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, // WBTC
            deployerKey: 0
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        // If we're on a local network, we need to deploy mock contracts
        // Check if we already have deployed mocks
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        // Deploy mock contracts
        vm.startBroadcast();
        // Deploy mock price feeds
        MockV3Aggregator wethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_INITIAL_PRICE);
        MockV3Aggregator wbtcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_INITIAL_PRICE);
        
        // Deploy mock tokens
        ERC20Mock weth = new ERC20Mock();
        ERC20Mock wbtc = new ERC20Mock();
        vm.stopBroadcast();

        return NetworkConfig({
            wethUsdPriceFeed: address(wethUsdPriceFeed),
            wbtcUsdPriceFeed: address(wbtcUsdPriceFeed),
            weth: address(weth),
            wbtc: address(wbtc),
            deployerKey: vm.envUint("ANVIL_PRIVATE_KEY")
        });
    }
} 