// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title StableCoin
 * @author Benson Wu
 * @notice This is a stable coin contract that is:
 * 1. Anchored/Pegged to USD
 * 2. Algorithmic (Decentralized)
 * 3. Exogenously Collateralized (ETH & BTC)
 * 
 * This contract is just the ERC20 implementation of our stablecoin system 
 * The ultimate owner of this contract should be the DSCEngine
 */
contract DecStableCoin is ERC20Burnable, Ownable {
    error DecStableCoin__InsufficientBalance(uint256 balance, uint256 amount);
    error DecStableCoin__InvalidAmount(uint256 amount);
    error DecStableCoin__ZeroAddress();

    constructor() ERC20("DecStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (balance < _amount) {
            revert DecStableCoin__InsufficientBalance(balance, _amount);
        } 
        if (_amount <= 0) {
            revert DecStableCoin__InvalidAmount(_amount);
        }
        super.burn(_amount); // super needed because we override burn()
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_amount <= 0) {
            revert DecStableCoin__InvalidAmount(_amount);
        }
        if (_to == address(0)) {
            revert DecStableCoin__ZeroAddress();
        }
        
        // _mint comes from ERC20.sol which we inherit through ERC20Burnable
        // It's an internal function that mints tokens to the specified address
        _mint(_to, _amount);
        return true;
    }
}
