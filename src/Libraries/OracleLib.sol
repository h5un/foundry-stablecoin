// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Benson Wu & DecentralizedStableCoin
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If a price is stale, functions will revert, and render the DSCEngine unusable - this is by design.
 * We want the DSCEngine to freeze if prices become stale.
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    /**
     * @notice Checks if the price feed data is stale
     * @param priceFeed The Chainlink price feed to check
     * @return roundId The round ID of the price feed
     * @return answer The current price
     * @return startedAt When the round started
     * @return updatedAt When the round was last updated
     * @return answeredInRound The round ID in which the answer was computed
     * @dev This function will revert if the price is stale
     */
    function staleCheckLatestRoundData(
        AggregatorV3Interface priceFeed
    ) public view returns (
        uint80,
        int256,
        uint256,
        uint256,
        uint80
    ) {
        (
            uint80 roundId,
            int256 answer, 
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        if (block.timestamp - updatedAt > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (
            roundId,
            answer,
            startedAt,
            updatedAt,
            answeredInRound
        );
    }
}
