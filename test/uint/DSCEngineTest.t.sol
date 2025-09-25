// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {ERC20Mock} from
//     "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";
import {ERC20DecimalsMock} from "../mocks/ERC20DecimalsMock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);

    DeployDSC depolyer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 wethDecimals;
    uint256 wbtcDecimals;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public amountToMint = 100 ether;

    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    // --- Test Setup ---

    function setUp() public {
        depolyer = new DeployDSC();
        (dsc, dscEngine, config) = depolyer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        // Mint some WETH to our USER for collateral
        // ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        // ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        ERC20DecimalsMock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20DecimalsMock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        wethDecimals = ERC20DecimalsMock(weth).decimals();
        wbtcDecimals = ERC20DecimalsMock(wbtc).decimals();
    }

    // --- Constructor Tests ---

    address[] public tokenAddress;
    address[] public priceFeedAddress;

    function testRevertsIfTokenLengthDosntMatchPriceFeeds() public {
        tokenAddress.push(weth);
        priceFeedAddress.push(ethUsdPriceFeed);
        priceFeedAddress.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch.selector);
        new DSCEngine(tokenAddress, priceFeedAddress, address(dsc));
    }

    // --- Price Tests ---

    // function testGetUsdValue() public view {
    //     uint256 ethAmount = 15e18; // 15 WETH
    //     // Default price in HelperConfig is $2000/ETH
    //     // 15 * 2000 = 30000
    //     uint256 expectedUsd = 30000e18;
    //     uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
    //     assertEq(actualUsd, expectedUsd);
    // }

    // function testGetTokenAmountFromUsd() public view {
    //     uint256 usdAmount = 100 ether; // $100
    //     // $100 / $2000/ETH = 0.05 ETH
    //     uint256 expectedWeth = 0.05 ether;
    //     uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
    //     assertEq(actualWeth, expectedWeth);
    // }

    function testGetWethTokenAmountFromUsd() public view {
        // If we want $10,000 of WETH @ $2000/WETH, that would be 5 WETH
        uint256 expectedWeth = 5 * (10 ** wethDecimals);
        uint256 amountWeth = dscEngine.getTokenAmountFromUsd(weth, 10000 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetWbtcTokenAmountFromUsd() public view {
        // If we want $10,000 of WBTC @ $1000/WBTC, that would be 10 WBTC
        uint256 expectedWbtc = 10 * (10 ** wbtcDecimals);
        uint256 amountWbtc = dscEngine.getTokenAmountFromUsd(wbtc, 10000 ether);
        assertEq(amountWbtc, expectedWbtc);
    }

    function testGetUsdValueWeth() public view {
        uint256 ethAmount = 15 * (10 ** wethDecimals);
        // 15 ETH * $2000/ETH = $30,000
        uint256 expectedUsd = 30000 ether;
        uint256 usdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testGetUsdValueWbtc() public view {
        uint256 btcAmount = 15 * (10 ** wbtcDecimals);
        // 15 BTC * $1000/BTC = $15,000
        uint256 expectedUsd = 15000 ether;
        uint256 usdValue = dscEngine.getUsdValue(wbtc, btcAmount);
        assertEq(usdValue, expectedUsd);
    }

    // --- depositCollateral Tests ---
    // This section tests the depositCollateral function thoroughly.

    function testRevertsIfTransferFromFails() public {
        // Arrange
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockCollateralToken);
        address[] memory feedAddresses = new address[](1);
        feedAddresses[0] = ethUsdPriceFeed;

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));

        mockCollateralToken.mint(USER, COLLATERAL_AMOUNT);

        vm.startPrank(USER);
        mockCollateralToken.approve(address(mockDsce), COLLATERAL_AMOUNT);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockCollateralToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        // Create a random, unallowed token
        // ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, COLLATERAL_AMOUNT);
        ERC20DecimalsMock randomToken = new ERC20DecimalsMock("RAN", "RAN", 18);
        vm.startPrank(USER);
        // We don't need to approve this token because the isAllowedToken modifier runs first
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(randomToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    // Modifier to set up a state where collateral is already deposited
    modifier depositedCollateral() {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValue);
    }

    // --- Minting DSC Tests ---

    function testRevertsIfMintFails() public {
        // Arrange
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = weth;
        address[] memory feedAddresses = new address[](1);
        feedAddresses[0] = ethUsdPriceFeed;
        address owner = msg.sender;

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(mockDsce), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(mockDsce), COLLATERAL_AMOUNT);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorIsBrokenOnMint() public depositedCollateral {
        // Get the USD value of our collateral
        // (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        // LIQUIDATION_THRESHOLD is 50, which means collateral must be 200% of debt.
        // Or, debt can be at most 50% of collateral value.
        // We try to mint slightly more than 50% to break the health factor.
        // uint256 amountToMint = (collateralValueInUsd / 2) + 1;

        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountToMint =
            (COLLATERAL_AMOUNT * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BrakesHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        // Mint an amount that should keep the health factor healthy
        // uint256 amountToMint = 100e18; // $100 DSC

        vm.startPrank(USER);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);

        assertEq(dsc.balanceOf(USER), amountToMint);
        assertEq(totalDscMinted, amountToMint);
    }

    // --- Combined Deposit & Mint Tests ---

    function testCanDepositAndMintInOneTx() public {
        // uint256 amountToMint = 100e18;

        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);

        assertEq(dsc.balanceOf(USER), amountToMint);
        assertEq(totalDscMinted, amountToMint);
    }

    // --- Burning DSC Tests ---

    modifier depositedAndMinted() {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, 100e18);
        vm.stopPrank();
        _;
    }

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCannotBurnMoreThanMinted() public depositedAndMinted {
        uint256 amountToBurn = 200e18; // We only minted 100 DSC

        vm.startPrank(USER);
        // This will revert in the DSC token's transferFrom, not a custom error from DSCEngine
        // We expect it to revert without a specific reason, hence no specific selector.
        vm.expectRevert();
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();
    }

    function testCanBurnDsc() public depositedAndMinted {
        uint256 initialDscBalance = dsc.balanceOf(USER);
        uint256 amountToBurn = initialDscBalance / 2;

        vm.startPrank(USER);
        // The DSCEngine needs approval to pull funds from the user to burn them
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        uint256 expectedDscBalance = initialDscBalance - amountToBurn;

        assertEq(dsc.balanceOf(USER), expectedDscBalance);
        assertEq(totalDscMinted, expectedDscBalance);
    }

    // --- Redeeming Collateral Tests ---

    function testEmitCollateralRedeemed() public depositedCollateral {
        vm.startPrank(USER);

        vm.expectEmit(true, true, false, true, address(dscEngine));
        emit CollateralRedeemed(USER, USER, weth, COLLATERAL_AMOUNT);
        dscEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);

        vm.stopPrank();
    }

    function testRevertsIfRedeemTransferFails() public {
        // Arrange
        address owner = msg.sender;
        MockFailedTransfer mockCollateral = new MockFailedTransfer();
        address[] memory tokenAddresses = new address[](1);
        tokenAddresses[0] = address(mockCollateral);
        address[] memory feedAddresses = new address[](1);
        feedAddresses[0] = ethUsdPriceFeed;

        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
        mockCollateral.mint(USER, COLLATERAL_AMOUNT);

        // vm.prank(owner);
        // // DSCEngine 必須是 collateral 的 owner 才能 transfer
        // mockCollateral.transfer(address(mockDsce), COLLATERAL_AMOUNT);

        vm.startPrank(USER);
        mockCollateral.approve(address(mockDsce), COLLATERAL_AMOUNT);

        // 關鍵修正：在嘗試贖回前，必須先存入
        mockDsce.depositCollateral(address(mockCollateral), COLLATERAL_AMOUNT);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockCollateral), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsIfHealthFactorIsBrokenOnRedeem() public depositedAndMinted {
        // Try to redeem all collateral, which will definitely break health factor.
        vm.startPrank(USER);
        // 這裡的 health factor 計算後也會是 0
        bytes memory expectedError = abi.encodeWithSelector(DSCEngine.DSCEngine__BrakesHealthFactor.selector, 0);
        vm.expectRevert(expectedError);
        dscEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedAndMinted {
        uint256 amountToRedeem = COLLATERAL_AMOUNT / 2;

        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, amountToRedeem);
        vm.stopPrank();

        // Check user's WETH balance. They started with STARTING_ERC20_BALANCE,
        // deposited COLLATERAL_AMOUNT, and redeemed amountToRedeem.
        uint256 expectedWethBalance = STARTING_ERC20_BALANCE - COLLATERAL_AMOUNT + amountToRedeem;
        assertEq(ERC20DecimalsMock(weth).balanceOf(USER), expectedWethBalance);
    }

    // --- Combined Redeem and Burn Tests ---

    function testCanRedeemAndBurnInOneTx() public depositedAndMinted {
        uint256 amountToBurn = 50e18;
        uint256 amountToRedeem = COLLATERAL_AMOUNT / 2;

        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.redeemCollateralForDsc(weth, amountToRedeem, amountToBurn);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);

        assertEq(dsc.balanceOf(USER), 50e18);
        assertEq(totalDscMinted, 50e18);
    }

    // --- Liquidation Tests ---

    // A more complex setup for liquidation scenarios
    modifier setupLiquidation() {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        // USER deposits 10 WETH ($20,000) and mints $10,000 DSC. Health factor is exactly 1.
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, 10000e18);
        vm.stopPrank();
        _;
    }

    // Modifier to set up a liquidated state
    modifier liquidated() {
        vm.startPrank(USER);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        ERC20DecimalsMock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        // Price of ETH drops, making the user liquidatable
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Setup liquidator
        uint256 collateralToCover = 20 ether; // a large amount
        // ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);
        ERC20DecimalsMock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        // ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        ERC20DecimalsMock(weth).approve(address(dscEngine), collateralToCover);
        // Liquidator needs DSC to pay the debt
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        // Act: Liquidate the user
        dscEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        // Assert: Check if liquidator received the correct amount of collateral (debt + bonus)
        // uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorWethBalance = ERC20DecimalsMock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWethPayout = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (
                dscEngine.getTokenAmountFromUsd(weth, amountToMint) * dscEngine.getLiquidationBonus()
                    / dscEngine.getLiquidationPrecision()
            );

        // The initial collateral was 20 WETH, minus the part that went back to DSCEngine, plus the liquidated amount
        // uint256 liquidatorInitialCollateral = 20 ether;

        // 斷言：清算人的最終餘額應該等於他應得的清算獎勵
        // 你的程式碼中可能錯誤地寫成了 assertEq(liquidatorWethBalance, collateralToCover + expectedWethPayout)
        assertEq(liquidatorWethBalance, expectedWethPayout);

        // 也可以使用 Trace 中的硬編碼值來驗證
        // uint256 hardCodedExpected = 6111111111111111110;
        // assertEq(liquidatorWethBalance, hardCodedExpected);
    }

    function testUserHasNoMoreDebtAfterLiquidation() public liquidated {
        // Assert: Check if the liquidated user's debt is now zero
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    function testUserStillHasSomeCollateralAfterLiquidation() public liquidated {
        // Assert: Check that the user didn't lose ALL their collateral
        // uint256 userWethBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 userWethBalance = ERC20DecimalsMock(weth).balanceOf(USER);
        // This will fail if the liquidation bonus is too high or collateral value is too low
        assertTrue(userWethBalance == 0); // In this specific scenario, the user loses all collateral because debt > collateral value.
            // A better test might use values where user retains some collateral.

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        assertTrue(userCollateralValueInUsd > 0);
    }

    function testRevertsIfHealthFactorIsOk() public setupLiquidation {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dscEngine.liquidate(weth, USER, 100e18);
        vm.stopPrank();
    }

    function testCannotLiquidateWithZeroDebt() public {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.liquidate(weth, USER, 0);
    }

    function testCanBeLiquidated() public setupLiquidation {
        // Scenario: Price of ETH drops from $2000 to $1000.
        // User's collateral was $20,000, now it's $10,000.
        // User's debt is $10,000.
        // Health Factor = ($10,000 * 50 / 100) / $10,000 = 0.5. User is liquidatable.

        // We need to update the price feed. We can do this by getting the MockV3Aggregator instance.
        // Price drops to $1000
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1200e8); // $1000 with 8 decimals

        // LIQUIDATOR needs DSC to pay back the user's debt. Let's give them some.
        // LIQUIDATOR 需要 DSC 來償還債務。讓他自己存抵押品來鑄造。
        uint256 debtToCover = 100e18; // $100 DSC
        uint256 collateralForLiquidator = 0.2 ether; // 0.2 WETH (~$240 at $1200/WETH)
        // ERC20Mock(weth).mint(LIQUIDATOR, collateralForLiquidator);
        ERC20DecimalsMock(weth).mint(LIQUIDATOR, collateralForLiquidator);

        vm.startPrank(LIQUIDATOR);
        // ERC20Mock(weth).approve(address(dscEngine), collateralForLiquidator);
        ERC20DecimalsMock(weth).approve(address(dscEngine), collateralForLiquidator);
        // Liquidator 存入 0.2 WETH，鑄造 100 DSC (保持健康)
        dscEngine.depositCollateralAndMintDsc(weth, collateralForLiquidator, debtToCover);
        dsc.approve(address(dscEngine), debtToCover);
        vm.stopPrank();

        // uint256 liquidatorInitialWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 liquidatorInitialWethBalance = ERC20DecimalsMock(weth).balanceOf(LIQUIDATOR);

        // 現在 LIQUIDATOR 有了 DSC，可以開始清算了
        vm.startPrank(LIQUIDATOR);
        dscEngine.liquidate(weth, USER, debtToCover);
        vm.stopPrank();

        // Check balances and state

        // 1. Liquidator's DSC should be burned
        assertEq(dsc.balanceOf(LIQUIDATOR), 0);

        // 2. User's DSC debt should be reduced
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 10000e18 - debtToCover);

        // 3. Liquidator receives user's collateral plus a bonus
        // At $1000/ETH, $100 debt = 0.1 ETH.
        uint256 tokenAmountFromDebt = dscEngine.getTokenAmountFromUsd(weth, debtToCover);
        // LIQUIDATION_BONUS is 10%. Bonus = 0.1 * 10 / 100 = 0.01 ETH.
        uint256 bonusCollateral = (tokenAmountFromDebt * 10) / 100;
        uint256 expectedCollateralForLiquidator = tokenAmountFromDebt + bonusCollateral;

        assertEq(
            ERC20DecimalsMock(weth).balanceOf(LIQUIDATOR),
            liquidatorInitialWethBalance + expectedCollateralForLiquidator
        );
    }

    function testLiquidationImprovesHealthFactor() public setupLiquidation {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1200e8); // Price drops, HF < 1

        uint256 startingUserHealthFactor = dscEngine.getHealthFactor(USER);

        // 同上，讓 LIQUIDATOR 透過正常管道取得 DSC
        uint256 debtToCover = 100e18;
        uint256 collateralForLiquidator = 0.1 ether;
        // ERC20Mock(weth).mint(LIQUIDATOR, collateralForLiquidator);
        ERC20DecimalsMock(weth).mint(LIQUIDATOR, collateralForLiquidator);

        vm.startPrank(LIQUIDATOR);
        // ERC20Mock(weth).approve(address(dscEngine), collateralForLiquidator);
        ERC20DecimalsMock(weth).approve(address(dscEngine), collateralForLiquidator);
        dscEngine.depositCollateralAndMintDsc(weth, collateralForLiquidator, debtToCover / 2);
        dsc.approve(address(dscEngine), debtToCover);
        dscEngine.liquidate(weth, USER, debtToCover / 2);
        vm.stopPrank();

        uint256 endingUserHealthFactor = dscEngine.getHealthFactor(USER);

        assertTrue(endingUserHealthFactor > startingUserHealthFactor);
    }

    // Bug Fix Test: [H-2] Liquidation fails when user has low collateral
    function testCantLiquidateWhenCollateralIsLow() public {
        // Arrange: Liquidator setup
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        ERC20DecimalsMock(weth).mint(liquidator, 100 ether);
        ERC20DecimalsMock(weth).approve(address(dscEngine), 100 ether);
        dscEngine.depositCollateralAndMintDsc(weth, 10 ether, 1000 ether); // Liquidator gets some DSC
        dsc.approve(address(dscEngine), 1000 ether);
        vm.stopPrank();

        // Arrange: User setup
        vm.startPrank(USER);
        ERC20DecimalsMock(weth).mint(USER, 10 ether);
        ERC20DecimalsMock(wbtc).mint(USER, 10 ether);
        ERC20DecimalsMock(weth).approve(address(dscEngine), 10 ether);
        ERC20DecimalsMock(wbtc).approve(address(dscEngine), 10 ether);
        // Set prices: WETH = $105, WBTC = $95
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(105e8);
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(95e8);
        dscEngine.depositCollateral(weth, 1 ether); // $105 collateral
        dscEngine.depositCollateralAndMintDsc(wbtc, 1 ether, 100 ether); // $95 collateral, $100 debt
        vm.stopPrank();

        // Act: WBTC price crashes
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(0); // User collateral is now only $105 WETH

        // Assert: Before the fix, this would revert.
        vm.expectRevert();
        vm.prank(liquidator);
        dscEngine.liquidate(weth, USER, 100 ether); // Try to liquidate the full $100 debt
    }

    // Bug Fix Test: [H-2] Liquidation fails when user has low collateral
    function testCanLiquidateWhenCollateralIsLow() public {
        // Arrange: A very healthy liquidator
        address liquidator = makeAddr("liquidator");
        vm.startPrank(liquidator);
        // 給清算人大量的 WETH，但只借一點點 DSC，讓他非常安全
        ERC20DecimalsMock(weth).mint(liquidator, 100 ether);
        ERC20DecimalsMock(weth).approve(address(dscEngine), 100 ether);
        dscEngine.depositCollateralAndMintDsc(weth, 50 ether, 100 ether); // $100k+ 抵押品, 只借 $100
        dsc.approve(address(dscEngine), 200 ether); // 預先授權足夠的 DSC 用於清算
        vm.stopPrank();

        // Arrange: A user in the critical H2 vulnerability zone
        vm.startPrank(USER);
        ERC20DecimalsMock(weth).mint(USER, 1 ether);
        ERC20DecimalsMock(weth).approve(address(dscEngine), 1 ether);

        // 設定 WETH 價格為 $105
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(105e8);

        // User 存入價值 $105 的抵押品，並借出 $100 DSC
        // 這使得他的抵押率剛好是 105%，處於無法支付 10% 全額獎金的臨界區
        dscEngine.depositCollateralAndMintDsc(weth, 1 ether, 100 ether);
        vm.stopPrank();

        // 檢查 user 的健康度，確認他處於不健康狀態
        uint256 startingUserHealthFactor = dscEngine.getHealthFactor(USER);
        uint256 MIN_HEALTH_FACTOR = dscEngine.getMinHealthFactor(); // 1.0 with 18 decimals
        assertTrue(startingUserHealthFactor < MIN_HEALTH_FACTOR);

        // Act: Liquidator performs the liquidation
        vm.prank(liquidator);
        dscEngine.liquidate(weth, USER, 100 ether); // 嘗試清算全部 $100 債務

        // Assert: 清算成功，壞帳被清除
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0); // User 的債務被完全清零

        // 清算人拿走了 User 所有的 WETH (1 ether)
        uint256 userCollateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(userCollateralBalance, 0);
    }
}
