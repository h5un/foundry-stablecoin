# Decentralized Stablecoin (DSC)

A decentralized stablecoin system built on Ethereum that maintains a 1:1 peg with USD through over-collateralization with crypto assets.

## Overview

DSC (Decentralized Stablecoin) is an ERC20 token that:
- Maintains a 1:1 peg to USD
- Is backed by exogenous crypto collateral (wETH and wBTC)
- Is algorithmically stable
- Is decentralized

## Key Features

### Stable Price Peg
- Uses Chainlink price feeds to maintain USD peg
- Price feeds have staleness checks to prevent using outdated data
- System freezes if price feeds become stale

### Over-collateralization
- Users must deposit more collateral value than DSC minted
- Minimum 150% collateralization ratio (health factor >= 1)
- Supports wETH and wBTC as collateral
- Users can be liquidated if health factor drops below 1

### Key Functions
- Deposit collateral
- Mint DSC
- Burn DSC
- Redeem collateral
- Liquidate under-collateralized positions

### Liquidations
- Anyone can liquidate positions below health factor of 1
- Liquidators receive a 10% bonus on collateral seized
- Must improve the position's health factor

## Architecture

The system consists of two main contracts:
- DSCEngine.sol: Core logic for minting, burning, liquidations
- DecStableCoin.sol: ERC20 token implementation

## Testing

Extensive testing suite including:
- Unit tests
- Integration tests  
- Fuzz tests
- Invariant tests

Key invariants maintained:
- Protocol collateral value >= Total DSC supply
- Getter functions never revert

## Security Features

- Reentrancy protection
- Checks-Effects-Interactions pattern
- Input validation and bounds checking
- Price feed staleness checks
- Pause mechanism on stale prices

## Author
Benson Wu