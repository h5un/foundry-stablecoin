// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecStableCoin} from "./DecStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Benson Wu
 * @notice This is the core of the DSC system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * 
 * Our DSC system should always be "over-collateralized"
 * 
 * The system is designed to maintain a 1 token == $1 peg
 * This contract is the core of the DSC system
 */
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved(uint256 userHealthFactor);

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address tokenAddress => address priceFeed) private s_priceFeed; // token to price feed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_dscMinted;
    address[] private s_tokenAllowed;

    DecStableCoin private immutable i_dsc;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);
    event Liquidation(
        address liquidator,
        address poorUser,
        address token,
        uint256 amountOfDscToBurn,
        uint256 totalCollateralToSeize
    );

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeed[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                      PUBLIC & EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(
        address[] memory tokenAddress,
        address[] memory priceFeedAddress,
        address dscAddress
    ) {
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeed[tokenAddress[i]] = priceFeedAddress[i];
            s_tokenAllowed.push(tokenAddress[i]);
        }

        i_dsc = DecStableCoin(dscAddress);  // Cast address to DecStableCoin type
    }

    /**
     * @notice Allows a user to deposit collateral and mint DSC tokens in one transaction
     * @param tokenCollateral The address of the token to deposit as collateral
     * @param amountToCollateralize The amount of collateral to deposit
     * @param amountToMint The amount of DSC to mint
     * @dev User must approve the DSCEngine to spend their collateral tokens before depositing
     * @dev The value of all collateral must be greater than the amount of DSC being minted
     */
    function depositCollateralAndMintDsc(
        address tokenCollateral,
        uint256 amountToCollateralize,
        uint256 amountToMint
    ) external {
        depositCollateral(tokenCollateral, amountToCollateralize);
        mintDsc(amountToMint);
    }

    /**
     * @notice Allows a user to deposit collateral into the protocol
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amount The amount of collateral to deposit
     * @dev User must approve the DSCEngine to spend their collateral tokens before depositing
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amount
    ) public
        moreThanZero(amount) 
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amount);

        // Interactions
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice Allows a user to burn DSC tokens and redeem collateral in a single transaction
     * @param token The address of the token to redeem as collateral
     * @param amountOfCollateralToRedeem The amount of collateral to redeem
     * @param amountOfDscToBurn The amount of DSC to burn
     * @dev Will first burn DSC tokens then redeem collateral
     * @dev Will revert if redeeming the collateral would drop health factor below 1
     * @dev User must have approved DSCEngine to spend their DSC tokens
     */
    function redeemCollateralForDsc(
        address token,
        uint256 amountOfCollateralToRedeem,
        uint256 amountOfDscToBurn
    ) external {
        burnDsc(amountOfDscToBurn);
        redeemCollateral(token, amountOfCollateralToRedeem); // Health factor already checked here.
    }

    /**
     * @notice Allows a user to redeem their collateral if they have enough collateral to maintain health factor > 1
     * @param token The address of the token to redeem
     * @param amount The amount of collateral to redeem
     * @dev Will revert if redeeming the collateral would drop health factor below 1
     */
    function redeemCollateral(
        address token,
        uint256 amount
    ) public moreThanZero(amount) nonReentrant isAllowedToken(token) 
    {
        _redeemCollateral(token, amount, msg.sender, msg.sender);

        // Make sure health factor is still good after redemption
        _revertIfHealthFactorBroken(msg.sender);
    }

    /**
     * @notice Allows a user to mint DSC tokens
     * @param amountToMint The amount of DSC to mint
     * @dev The value of all collateral must be greater than the amount of DSC being minted
     * @dev User must have deposited collateral before minting DSC
     */
    function mintDsc(uint256 amountToMint) public moreThanZero(amountToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountToMint;
        // Check if minting puts their health factor at a good level
        _revertIfHealthFactorBroken(msg.sender);
        // If the check passes, mint DSC to the user
        bool mintSuccess = i_dsc.mint(msg.sender, amountToMint);
        if (!mintSuccess) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) nonReentrant {
        _burnDsc(amount, msg.sender, msg.sender);
    }

    /**
     * @notice If a user's health factor goes below 1, they can be liquidated
     * @dev A user can be liquidated if the value of their collateral * liquidation threshold < value of DSC borrowed
     * Anyone can liquidate a user who has broken the health factor
     * @param token The collateral token to liquidate
     * @param poorUser The user who has broken the health factor
     * @param amountOfDscToBurn The amount of DSC to burn to improve the user's health factor
     */
    function liquidate(
        address token,
        address poorUser,
        uint256 amountOfDscToBurn
    ) external moreThanZero(amountOfDscToBurn) nonReentrant isAllowedToken(token) {
        // Check if user can be liquidated (health factor < 1)
        uint256 userHealthFactor = _healthFactor(poorUser);
        if (userHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // Calculate amount of collateral to seize
        // We give a 10% bonus to liquidators as incentive
        uint256 tokenAmountFromDscAmount = getTokenAmountFromUsd(token, amountOfDscToBurn);
        uint256 bonusCollateral = (tokenAmountFromDscAmount * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION; // Incentive
        uint256 totalCollateralToSeize = tokenAmountFromDscAmount + bonusCollateral;
        _redeemCollateral(token, totalCollateralToSeize, poorUser, msg.sender);

        // Burn the liquidator's dsc on behalf of the poor user
        _burnDsc(amountOfDscToBurn, poorUser, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(poorUser);
        if (endingUserHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved(endingUserHealthFactor);
        }
        _revertIfHealthFactorBroken(msg.sender);

        emit Liquidation(msg.sender, poorUser, token, amountOfDscToBurn, totalCollateralToSeize);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHealthFactor(address user) external view returns (uint256 healthFactor) {
        healthFactor = _healthFactor(user);
        return healthFactor;
    }

    function getAccountCollateralValue(address user) public view returns (uint256){
        // Loop through each collateral token, get the amount deposited.
        // Then, map it to the price to get the USD value.
        uint256 totalValue = 0;
        for (uint256 i = 0; i < s_tokenAllowed.length; i++) {
            address token = s_tokenAllowed[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalValue += getUsdValue(token, amount);
        }
        return totalValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1e8 is the decimals returned by Chainlink price feeds
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
    
    function getCollateralDeposited(address user, address token) public view returns (uint256 amount) {
        return s_collateralDeposited[user][token];
    }

    function getTokenAmountFromUsd(address token, uint256 amountOfDsc) public view returns (uint amountOfToken) {
        // Get price feed for token
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // Convert USD amount to token amount accounting for decimals
        amountOfToken = (amountOfDsc * PRECISION ) / (ADDITIONAL_FEED_PRECISION * uint256(price));
        return amountOfToken;
    }

    function getDscMinted(address user) public view returns (uint256) {
        return s_dscMinted[user];
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_tokenAllowed;
    }

    /*//////////////////////////////////////////////////////////////
                      PRIVATE & INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _healthFactor(address user) private view returns (uint256) {
        // Get total DSC minted
        uint256 totalDscMinted = s_dscMinted[user];
        if (totalDscMinted == 0) return type(uint256).max;
        
        // Get total collateral value in USD
        uint256 collateralValueInUsd = getAccountCollateralValue(user);
        
        // Adjust collateral value by threshold
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        
        // Return health factor
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorBroken(address user) internal view {
        // 1. Get health factor
        uint256 userHealthFactor = _healthFactor(user);
        // 2. If health factor is broken (< MIN_HEALTH_FACTOR = 1), revert
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address token, uint256 amountOfCollateral, address _from, address _to) private {
        // Update user's collateral balance and emit event
        s_collateralDeposited[_from][token] -= amountOfCollateral;
        emit CollateralRedeemed(_from, _to, token, amountOfCollateral);

        // Transfer collateral
        bool success = IERC20(token).transfer(_to, amountOfCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /// @notice Burns DSC tokens and updates the minted balance for a user
    /// @dev This is called during liquidation and when users want to repay their DSC
    /// @param amountToBurn The amount of DSC to burn
    /// @param onBehalfOf The address whose DSC minted balance will be reduced
    /// @param from The address from which to transfer the DSC tokens
    function _burnDsc(uint256 amountToBurn, address onBehalfOf, address from) private {
        // Decrease poor user's DSC balance
        // This will revert on underflow if trying to burn too much
        s_dscMinted[onBehalfOf] -= amountToBurn; 
        // Transfer DSC from the liquidator(payer) to this contract
        bool success = i_dsc.transferFrom(from, address(this), amountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        // Burn the DSC tokens
        i_dsc.burn(amountToBurn);
    }
}