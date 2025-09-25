// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine(Decentralized Stable Coin Engine)
 * @author Yu-Wei Chang
 *
 * The system is desgined to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral (ETH & BTC)
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH & WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all logics for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI Stable System) - but many of the mechanisms have been simplified / removed for the sake of learning.
 *
 */
contract DSCEngine is ReentrancyGuard {
    //--- Errors ---
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BrakesHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOK();
    error DSCEngine__HealthFactorNotImproved();

    // --- Type Declarations ---
    using OracleLib for AggregatorV3Interface;

    //--- State Variables ---
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100; // 50 / 100 = 0.5
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; // 1 * 10^18
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%

    /// @dev Mapping of token address to price feed address
    mapping(address token => address priceFeed) private s_priceFeeds; // token address -> price feed address

    /// @dev Mapping of token address to decimals
    mapping(address token => uint8 decimals) private s_tokenDecimals; // token address -> token decimals

    /// @dev Amount of collateral deposited by each user
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // user address -> token address -> collateral amount

    /// @dev Amount of DSC minted by each user
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //--- Events ---
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    //--- Modifiers ---
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    //--- Functions ---
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
        }

        // For example ETH/USD, BTC/USD, MKR/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
            // aderyn-ignore-next-line(reentrancy-state-change)
            uint8 tokenDecimals = IERC20Metadata(tokenAddresses[i]).decimals();
            s_tokenDecimals[tokenAddresses[i]] = tokenDecimals;
        }

        // 透過地址(dscAddress)，創建一個符合 DecentralizedStableCoin 介面的合約實例
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //--- External Functions ---

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    /**
     * @notice Deposit collateral into the DSC system and mint DSC tokens.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to deposit.
     * @param amountDscToMint The amount of DSC tokens to mint.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Deposit collateral into the DSC system and mint DSC tokens.
     * @notice follows CEI (Checks-Effects-Interactions) pattern.
     * @dev This function is non-reentrant and checks that the collateral amount is greater than zero.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to deposit.
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @notice This function burns DSC and redeems underlying collateral in one transaction.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to redeem.
     * @param amountDscToBurn The amount of DSC tokens to burn.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // In order to redeem collateral:
    // 1. Health factor must be over 1 AFTER collateral is withdrawn
    // CEI (Checks-Effects-Interactions) pattern
    // 補充）DRY原則: Don't repeat yourself
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        nonReentrant
        moreThanZero(amountCollateral)
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function follows the CEI (Checks-Effects-Interactions) pattern.
     * @param amountDscToMint The amount of DSC tokens to mint.
     * @notice They must have more collateral value than the minimum threshold.
     */
    function mintDsc(uint256 amountDscToMint) public nonReentrant moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender); // If they minted too much ($150 DSC, $100 ETH)
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amountToBurn) public moreThanZero(amountToBurn) {
        _burnDsc(amountToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This line might never be reached...
    }

    /**
     * @notice This function liquidates a user's collateral if their health factor is broken.
     * @param collateral The address of the collateral token contract.
     * @param user The address of the user to liquidate. Their _healthFactor must be below MIN_HEALTH_FACTOR.
     * @param debtToCover The amount of DSC you want to burn to improve the user's health factor.
     * @dev You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        public
        nonReentrant
        moreThanZero(debtToCover)
    {
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOK();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        // H2-Fix: If the user doesn't have enough collateral to cover the bonus,
        // give the liquidator all of their collateral of that type.
        uint256 userCollateralBalance = s_collateralDeposited[user][collateral];
        if (totalCollateralToRedeem > userCollateralBalance) {
            totalCollateralToRedeem = userCollateralBalance;
        }

        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //--- Private & Internal Functions ---
    /**
     * @notice Burns DSC tokens on behalf of a user.
     * @param amountDscToBurn The amount of DSC tokens to burn.
     * @param onBehalfOf The address of the user to burn tokens for.
     * @param dscFrom The address of the DSC token contract.
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factor being broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /**
     * @notice Redeem collateral from a user.
     * @param from The address of the user to redeem collateral from.
     * @param to The address to send the redeemed collateral to.
     * @param tokenCollateralAddress The address of the collateral token contract.
     * @param amountCollateral The amount of collateral to redeem.
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    /**
     * @notice Get the health factor of a user.
     * @param user The address of the user.
     * @return The health factor of the user.
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);

        // 如果用戶沒有鑄造任何 DSC，他們的健康狀況是無限的。
        // if (totalDscMinted == 0) {
        //     return type(uint256).max;
        // }

        // collateralAdjustedForThreshold 算出來代表 user 最低需要兩倍的抵押品價值，才能維持在健康的狀態
        // uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // $1000 ETH / 100 DSC
        // $1000 ETH * 50 / 100 = $500 -> 500 / 100 DSC > 1 (Healthy)
        // return ((collateralAdjustedForThreshold * PRECISION) / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1.Check health factor (do they have enough collateral?)
        // 2.Revert if health factor is broken
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BrakesHealthFactor(healthFactor);
        }
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return ((collateralAdjustedForThreshold * 1e18) / totalDscMinted);
    }

    //--- Public & External View Functions ---

    /**
     * @notice Get the amount of collateral tokens needed to mint a specific USD amount.
     * @param token The address of the collateral token contract.
     * @param usdAmountInWei The amount of USD to convert to collateral tokens.
     *
     * [25'0922] Bug Fix: [H-1] Theft of collateral tokens with fewer than 18 decimals
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000. The returned value from CL will be 1000 * 1e8
        // return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION); // (1000e18 * 1e18) / (1000 * 1e8 * 1e10) = 1e18

        uint8 tokenDecimals = s_tokenDecimals[token];
        uint8 priceFeedDecimals = priceFeed.decimals();
        return (usdAmountInWei * (10 ** (priceFeedDecimals + tokenDecimals)) / (uint256(price) * PRECISION)); // (1000e18 * 1e8 * 1e8) / (1000 * 1e8 * 1e18) = 1e8
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and then get the price of that collateral token -> USD value
        // ex: 1 ETH -> $1,500
        // ex: 0.5 BTC -> $10,000
        // add them up -> total value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * @notice Get the USD value of a specific amount of a collateral token.
     * @param token The address of the collateral token contract.
     * @param amount The amount of the collateral token to convert to USD.
     * @return The USD value of the specified amount of the collateral token.
     *
     * [25'0922] Bug Fix: [H-1] Theft of collateral tokens with fewer than 18 decimals
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = $1000. The returned value from CL will be 1000 * 1e8
        // return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // ((1000 * 1e8 * 1e10) * 1000) / 1e18

        // Example: 1 WBTC (amount = 1e8) priced at $30,000 (price = 30000e8)
        // should return 30000e18
        uint8 tokenDecimals = s_tokenDecimals[token];
        uint8 priceFeedDecimals = priceFeed.decimals();
        return (uint256(price) * amount * PRECISION) / (10 ** (priceFeedDecimals + tokenDecimals)); // (30000e8 * 1e8 * 1e18) / (1e8 * 1e8) = 30000e18
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
