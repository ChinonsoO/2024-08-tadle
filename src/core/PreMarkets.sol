// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PerMarketsStorage} from "../storage/PerMarketsStorage.sol";
import {OfferStatus, AbortOfferStatus, OfferType, OfferSettleType} from "../storage/OfferStatus.sol";
import {StockStatus, StockType} from "../storage/OfferStatus.sol";
import {ITadleFactory} from "../factory/ITadleFactory.sol";
import {ITokenManager, TokenBalanceType} from "../interfaces/ITokenManager.sol";
import {ISystemConfig, MarketPlaceInfo, MarketPlaceStatus, ReferralInfo} from "../interfaces/ISystemConfig.sol";
import {IPerMarkets, OfferInfo, StockInfo, MakerInfo, CreateOfferParams} from "../interfaces/IPerMarkets.sol";
import {IWrappedNativeToken} from "../interfaces/IWrappedNativeToken.sol";
import {RelatedContractLibraries} from "../libraries/RelatedContractLibraries.sol";
import {MarketPlaceLibraries} from "../libraries/MarketPlaceLibraries.sol";
import {OfferLibraries} from "../libraries/OfferLibraries.sol";
import {GenerateAddress} from "../libraries/GenerateAddress.sol";
import {Constants} from "../libraries/Constants.sol";
import {Rescuable} from "../utils/Rescuable.sol";
import {Related} from "../utils/Related.sol";
import {Errors} from "../utils/Errors.sol";

/**
 * @title PreMarkets
 * @notice Implement the pre market
 */

//e- Good general explanation of protocol: https://chatgpt.com/share/67dd7c44-3294-800d-971a-942d263faeb4
contract PreMarktes is PerMarketsStorage, Rescuable, Related, IPerMarkets {
    using Math for uint256;
    using RelatedContractLibraries for ITadleFactory;
    using MarketPlaceLibraries for MarketPlaceInfo;

    constructor() Rescuable() {}

    /**
     * @notice Create offer
     * @dev params must be valid, details in CreateOfferParams
     * @dev points and amount must be greater than 0
     */
    function createOffer(CreateOfferParams calldata params) external payable {
        /**
         * @dev points and amount must be greater than 0
         * @dev eachTradeTax must be less than 100%, decimal scaler is 10000
         * @dev collateralRate must be more than 100%, decimal scaler is 10000
         */
        if (params.points == 0x0 || params.amount == 0x0) {
            revert Errors.AmountIsZero();
        }

        if (params.eachTradeTax > Constants.EACH_TRADE_TAX_DECIMAL_SCALER) {
            revert InvalidEachTradeTaxRate();
        }

        if (params.collateralRate < Constants.COLLATERAL_RATE_DECIMAL_SCALER) {
            revert InvalidCollateralRate();
        }

        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();
        MarketPlaceInfo memory marketPlaceInfo = systemConfig
            .getMarketPlaceInfo(params.marketPlace);
        marketPlaceInfo.checkMarketPlaceStatus(
            block.timestamp,
            MarketPlaceStatus.Online
        );

        /// @dev generate address for maker, offer, stock.
        address makerAddr = GenerateAddress.generateMakerAddress(offerId);
        address offerAddr = GenerateAddress.generateOfferAddress(offerId);
        address stockAddr = GenerateAddress.generateStockAddress(offerId);

        if (makerInfoMap[makerAddr].authority != address(0x0)) {
            revert MakerAlreadyExist();
        }

        if (offerInfoMap[offerAddr].authority != address(0x0)) {
            revert OfferAlreadyExist();
        }

        if (stockInfoMap[stockAddr].authority != address(0x0)) {
            revert StockAlreadyExist();
        }

        offerId = offerId + 1;

        {
            /// @dev transfer collateral from _msgSender() to capital pool
            uint256 transferAmount = OfferLibraries.getDepositAmount(
                params.offerType,
                params.collateralRate,
                params.amount,
                true,
                Math.Rounding.Ceil
            );

            ITokenManager tokenManager = tadleFactory.getTokenManager();
            tokenManager.tillIn{value: msg.value}(
                _msgSender(),
                params.tokenAddress,
                transferAmount,
                false
            );
        }

        /// @dev update maker info

        //q-We're rewriting maker info each time?
        makerInfoMap[makerAddr] = MakerInfo({
            offerSettleType: params.offerSettleType,
            authority: _msgSender(),
            marketPlace: params.marketPlace,
            tokenAddress: params.tokenAddress,
            originOffer: offerAddr,
            platformFee: 0,
            eachTradeTax: params.eachTradeTax
        });

        /// @dev update offer info
        offerInfoMap[offerAddr] = OfferInfo({
            id: offerId,
            authority: _msgSender(),
            maker: makerAddr,
            offerStatus: OfferStatus.Virgin,
            offerType: params.offerType,
            points: params.points,
            amount: params.amount,
            collateralRate: params.collateralRate,
            abortOfferStatus: AbortOfferStatus.Initialized,
            usedPoints: 0,
            tradeTax: 0,
            settledPoints: 0,
            settledPointTokenAmount: 0,
            settledCollateralAmount: 0
        });

        /// @dev update stock info
        stockInfoMap[stockAddr] = StockInfo({
            id: offerId,
            stockStatus: StockStatus.Initialized,
            stockType: params.offerType == OfferType.Ask
                ? StockType.Bid
                : StockType.Ask,
            authority: _msgSender(),
            maker: makerAddr,
            preOffer: address(0x0),
            offer: offerAddr,
            points: params.points,
            amount: params.amount
        });

        emit CreateOffer(
            offerAddr,
            makerAddr,
            stockAddr,
            params.marketPlace,
            _msgSender(),
            params.points,
            params.amount
        );
    }

    /**
     * @notice Create taker
     * @param _offer offer address
     * @param _points points
     */
    function createTaker(address _offer, uint256 _points) external payable {
        /**
         * @dev offer must be virgin
         * @dev points must be greater than 0
         * @dev total points must be greater than used points plus _points
         */
        if (_points == 0x0) {
            revert Errors.AmountIsZero();
        }

        OfferInfo storage offerInfo = offerInfoMap[_offer];
        MakerInfo storage makerInfo = makerInfoMap[offerInfo.maker];
        //@audit - We don't update our offerStatus to ongoing /filled.
        if (offerInfo.offerStatus != OfferStatus.Virgin) {
            revert InvalidOfferStatus();
        }

        if (offerInfo.points < _points + offerInfo.usedPoints) {
            revert NotEnoughPoints(
                offerInfo.points,
                offerInfo.usedPoints,
                _points
            );
        }

        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();
        {
            MarketPlaceInfo memory marketPlaceInfo = systemConfig
                .getMarketPlaceInfo(makerInfo.marketPlace);
            marketPlaceInfo.checkMarketPlaceStatus(
                block.timestamp,
                MarketPlaceStatus.Online
            );
        }

        ReferralInfo memory referralInfo = systemConfig.getReferralInfo(
            _msgSender()
        );

        uint256 platformFeeRate = systemConfig.getPlatformFeeRate(_msgSender());

        /// @dev generate stock address
        address stockAddr = GenerateAddress.generateStockAddress(offerId);
        if (stockInfoMap[stockAddr].authority != address(0x0)) {
            revert StockAlreadyExist();
        }

        /// @dev Transfer token from user to capital pool as collateral
        uint256 depositAmount = _points.mulDiv(
            offerInfo.amount, //pretty much the price
            offerInfo.points, //Points we're selling
            Math.Rounding.Ceil
        );
        uint256 platformFee = depositAmount.mulDiv(
            platformFeeRate,
            Constants.PLATFORM_FEE_DECIMAL_SCALER
        );
        uint256 tradeTax = depositAmount.mulDiv(
            makerInfo.eachTradeTax,
            Constants.EACH_TRADE_TAX_DECIMAL_SCALER
        );

        ITokenManager tokenManager = tadleFactory.getTokenManager();
        _depositTokenWhenCreateTaker(
            platformFee,
            depositAmount,
            tradeTax,
            makerInfo,
            offerInfo,
            tokenManager
        );

        offerInfo.usedPoints = offerInfo.usedPoints + _points;

        /// @dev update stock info
        stockInfoMap[stockAddr] = StockInfo({
            id: offerId,
            stockStatus: StockStatus.Initialized,
            stockType: offerInfo.offerType == OfferType.Ask //if someone is selling, that means we had to buy it
                ? StockType.Bid
                : StockType.Ask,
            authority: _msgSender(), //ok so our authority is the person who is buying the stock
            maker: offerInfo.maker,
            preOffer: _offer,
            points: _points, //stock worth
            amount: depositAmount, //how much we bought or sold our stock for
            offer: address(0x0) //q- Is this is case we want to relist it later?
        });

        offerId = offerId + 1;
        uint256 remainingPlatformFee = _updateReferralBonus(
            platformFee,
            depositAmount,
            stockAddr,
            makerInfo,
            referralInfo,
            tokenManager
        );

        makerInfo.platformFee = makerInfo.platformFee + remainingPlatformFee;

        _updateTokenBalanceWhenCreateTaker(
            _offer,
            tradeTax,
            depositAmount,
            offerInfo,
            makerInfo,
            tokenManager
        );

        /// @dev emit CreateTaker
        emit CreateTaker(
            _offer,
            msg.sender,
            stockAddr,
            _points,
            depositAmount,
            tradeTax,
            remainingPlatformFee
        );
    }

    /**
     * @notice list offer
     * @param _stock stock address
     * @param _amount the amount of offer
     * @param _collateralRate offer collateral rate
     * @dev Only stock owner can list offer
     * @dev Market place must be online
     * @dev Only ask offer can be listed
     */
    function listOffer(
        address _stock,
        uint256 _amount,
        uint256 _collateralRate
    ) external payable {
        if (_amount == 0x0) {
            revert Errors.AmountIsZero();
        }

        if (_collateralRate < Constants.COLLATERAL_RATE_DECIMAL_SCALER) {
            revert InvalidCollateralRate();
        }

        StockInfo storage stockInfo = stockInfoMap[_stock];
        if (_msgSender() != stockInfo.authority) {
            revert Errors.Unauthorized();
        }

        //q- We don't check if this is zero what is the impact?
        OfferInfo storage offerInfo = offerInfoMap[stockInfo.preOffer];
        MakerInfo storage makerInfo = makerInfoMap[offerInfo.maker];

        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();
        MarketPlaceInfo memory marketPlaceInfo = systemConfig
            .getMarketPlaceInfo(makerInfo.marketPlace);

        marketPlaceInfo.checkMarketPlaceStatus(
            block.timestamp,
            MarketPlaceStatus.Online
        );

        if (stockInfo.offer != address(0x0)) {
            revert OfferAlreadyExist();
        }

        if (stockInfo.stockType != StockType.Bid) {
            revert InvalidStockType(StockType.Bid, stockInfo.stockType);
        }

        /// @dev change abort offer status when offer settle type is turbo
        if (makerInfo.offerSettleType == OfferSettleType.Turbo) {
            address originOffer = makerInfo.originOffer;
            //@audit - We're not writing to storage here when we should be
            OfferInfo memory originOfferInfo = offerInfoMap[originOffer];

            if (_collateralRate != originOfferInfo.collateralRate) {
                revert InvalidCollateralRate(); //Why are we reverting here?
            }
            originOfferInfo.abortOfferStatus = AbortOfferStatus.SubOfferListed;
            //q- when settle type is turbo, we say that the original offter now how a sub offer listed.
        }

        /// @dev transfer collateral when offer settle type is protected
        if (makerInfo.offerSettleType == OfferSettleType.Protected) {
            //q- why are we not updating the abort offer status here?

            uint256 transferAmount = OfferLibraries.getDepositAmount(
                offerInfo.offerType,
                offerInfo.collateralRate,
                _amount,
                true,
                Math.Rounding.Ceil
            );

            ITokenManager tokenManager = tadleFactory.getTokenManager();
            tokenManager.tillIn{value: msg.value}(
                _msgSender(),
                makerInfo.tokenAddress,
                transferAmount,
                false
            );
        }

        address offerAddr = GenerateAddress.generateOfferAddress(stockInfo.id);
        if (offerInfoMap[offerAddr].authority != address(0x0)) {
            revert OfferAlreadyExist();
        }

        /// @dev update offer info
        //q-doesn't this just revert since we're reusing the same offer Id.
        //a- The reason this doesn't revert is because we're checking agains the offerInfoMap,
        //we only populate the stockInfoMap when we create a taker.
        offerInfoMap[offerAddr] = OfferInfo({
            id: stockInfo.id,
            authority: _msgSender(),
            maker: offerInfo.maker, //q- Should this not be msg.sender?
            offerStatus: OfferStatus.Virgin,
            offerType: offerInfo.offerType,
            abortOfferStatus: AbortOfferStatus.Initialized,
            points: stockInfo.points,
            amount: _amount,
            collateralRate: _collateralRate,
            usedPoints: 0,
            tradeTax: 0,
            settledPoints: 0,
            settledPointTokenAmount: 0,
            settledCollateralAmount: 0
        });

        stockInfo.offer = offerAddr;

        emit ListOffer(
            offerAddr,
            _stock,
            _msgSender(),
            stockInfo.points,
            _amount
        );
    }

    /**
     * @notice close offer
     * @param _stock stock address
     * @param _offer offer address
     * @notice Only offer owner can close offer
     * @dev Market place must be online
     * @dev Only offer status is virgin can be closed
     */
    function closeOffer(address _stock, address _offer) external {
        OfferInfo storage offerInfo = offerInfoMap[_offer];
        StockInfo storage stockInfo = stockInfoMap[_stock];

        if (stockInfo.offer != _offer) {
            revert InvalidOfferAccount(stockInfo.offer, _offer);
        }

        if (offerInfo.authority != _msgSender()) {
            revert Errors.Unauthorized();
        }

        if (offerInfo.offerStatus != OfferStatus.Virgin) {
            revert InvalidOfferStatus();
        }

        MakerInfo storage makerInfo = makerInfoMap[offerInfo.maker];
        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();
        MarketPlaceInfo memory marketPlaceInfo = systemConfig
            .getMarketPlaceInfo(makerInfo.marketPlace);

        marketPlaceInfo.checkMarketPlaceStatus(
            block.timestamp,
            MarketPlaceStatus.Online
        );

        /**
         * @dev update refund token from capital pool to balance
         * @dev offer settle type is protected or original offer
         */
        //q- so we don't refund when turbo mode becuase users don't deposit collateral
         //except for the original offer who has to have collaretal for all trades
        if (
            makerInfo.offerSettleType == OfferSettleType.Protected ||
            stockInfo.preOffer == address(0x0)
        ) {
            uint256 refundAmount = OfferLibraries.getRefundAmount(
                offerInfo.offerType,
                offerInfo.amount,
                offerInfo.points,
                offerInfo.usedPoints,
                offerInfo.collateralRate
            );

            ITokenManager tokenManager = tadleFactory.getTokenManager();
            tokenManager.addTokenBalance(
                TokenBalanceType.MakerRefund,
                _msgSender(),
                makerInfo.tokenAddress,
                refundAmount
            );
        }

        offerInfo.offerStatus = OfferStatus.Canceled;
        emit CloseOffer(_offer, _msgSender());
    }

    /**
     * @notice relist offer
     * @param _stock stock address
     * @param _offer offer address
     * @notice Only offer owner can relist offer
     * @dev Market place must be online
     * @dev Only offer status is canceled can be relisted
     */
    function relistOffer(address _stock, address _offer) external payable {
        OfferInfo storage offerInfo = offerInfoMap[_offer];
        StockInfo storage stockInfo = stockInfoMap[_stock];

        if (stockInfo.offer != _offer) {
            revert InvalidOfferAccount(stockInfo.offer, _offer);
        }

        if (offerInfo.authority != _msgSender()) {
            revert Errors.Unauthorized();
        }

        if (offerInfo.offerStatus != OfferStatus.Canceled) {
            revert InvalidOfferStatus();
        }

        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();

        MakerInfo storage makerInfo = makerInfoMap[offerInfo.maker];
        MarketPlaceInfo memory marketPlaceInfo = systemConfig
            .getMarketPlaceInfo(makerInfo.marketPlace);

        marketPlaceInfo.checkMarketPlaceStatus(
            block.timestamp,
            MarketPlaceStatus.Online
        );

        /**
         * @dev transfer refund token from user to capital pool
         * @dev offer settle type is protected or original offer
         */
        if (
            makerInfo.offerSettleType == OfferSettleType.Protected ||
            stockInfo.preOffer == address(0x0)
        ) {
            uint256 depositAmount = OfferLibraries.getRefundAmount(
                offerInfo.offerType,
                offerInfo.amount,
                offerInfo.points,
                offerInfo.usedPoints,
                offerInfo.collateralRate
            );

            ITokenManager tokenManager = tadleFactory.getTokenManager();
            tokenManager.tillIn{value: msg.value}(
                _msgSender(),
                makerInfo.tokenAddress,
                depositAmount,
                false
            );
        }

        /// @dev update offer status to virgin
        //@audit- An offer that is being relisted may still have used points, we should not be setting the status back to virgin.
        offerInfo.offerStatus = OfferStatus.Virgin;
        emit RelistOffer(_offer, _msgSender());
    }

    /**
     * @notice abort ask offer
     * @param _stock stock address
     * @param _offer offer address
     * @notice Only offer owner can abort ask offer
     * @dev Only offer status is virgin or canceled can be aborted
     * @dev Market place must be online
     */
    function abortAskOffer(address _stock, address _offer) external {
        StockInfo storage stockInfo = stockInfoMap[_stock];
        OfferInfo storage offerInfo = offerInfoMap[_offer];

        if (offerInfo.authority != _msgSender()) {
            revert Errors.Unauthorized();
        }

        if (stockInfo.offer != _offer) {
            revert InvalidOfferAccount(stockInfo.offer, _offer);
        }

        if (offerInfo.offerType != OfferType.Ask) {
            revert InvalidOfferType(OfferType.Ask, offerInfo.offerType);
        }

        if (offerInfo.abortOfferStatus != AbortOfferStatus.Initialized) {
            revert InvalidAbortOfferStatus(
                AbortOfferStatus.Initialized,
                offerInfo.abortOfferStatus
            );
        }

        if (
            offerInfo.offerStatus != OfferStatus.Virgin &&
            offerInfo.offerStatus != OfferStatus.Canceled
        ) {
            revert InvalidOfferStatus();
        }

        MakerInfo storage makerInfo = makerInfoMap[offerInfo.maker];

        //for turbo offers it must be the original offer
        //for protected offers its fine.
        if (
            makerInfo.offerSettleType == OfferSettleType.Turbo &&
            stockInfo.preOffer != address(0x0)
        ) {
            revert InvalidOffer();
        }

        /// @dev market place must be online
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();
        MarketPlaceInfo memory marketPlaceInfo = systemConfig
            .getMarketPlaceInfo(makerInfo.marketPlace);
        marketPlaceInfo.checkMarketPlaceStatus(
            block.timestamp,
            MarketPlaceStatus.Online
        );

        uint256 remainingAmount;
        if (offerInfo.offerStatus == OfferStatus.Virgin) {
            remainingAmount = offerInfo.amount;
        } else {
            //@audit - This calculation is incorrect.
            //It should be remainingAmount = offerInfo.amount - offerInfo.amount.mulDiv(offerInfo.usedPoints, offerInfo.points, Math.Rounding.Floor);
            remainingAmount = offerInfo.amount.mulDiv(
                offerInfo.usedPoints,
                offerInfo.points,
                Math.Rounding.Floor
            );
        }
        
        //Returns our amount that we transfered(due to our collateral rate). Ex. if our collateral rate was 1.2 and our
        //remaining amount is 450 we can multiply our collateral * remaining amount to find out how much of what we transferred.

        //The below calculations were tested with a supposed remainingAmount of 450, usedPoints of 100, totalPoints of 1000,
        //amount of 500.

        //Correct Calculation 450 * 1.2 = 600
        uint256 transferAmount = OfferLibraries.getDepositAmount(
            offerInfo.offerType,
            offerInfo.collateralRate,
            remainingAmount,
            true,
            Math.Rounding.Floor
        );
        //Correct calculation

        //500 * 100 / 1000 = 50
        uint256 totalUsedAmount = offerInfo.amount.mulDiv(
            offerInfo.usedPoints,
            offerInfo.points,
            Math.Rounding.Ceil
        );
        
        //assuming a collaterall rate of 1.2 this gives us 50 * 1.2 = 60 
        //correct calcuation.
        uint256 totalDepositAmount = OfferLibraries.getDepositAmount(
            offerInfo.offerType,
            offerInfo.collateralRate,
            totalUsedAmount,
            false,
            Math.Rounding.Ceil
        );

        ///@dev update refund amount for offer authority
        uint256 makerRefundAmount;

        //600 - 60 = 540, This is correct -> 450 * 1.2 = 540, if our original amount was 500 its means our collateralized total was 
        //500 * 1.2 = 600. Doing 600 - 60 gives us 540 which is how much we expect to get back as a refund.
        if (transferAmount > totalDepositAmount) {
            makerRefundAmount = transferAmount - totalDepositAmount;
        } else {
            makerRefundAmount = 0;
        }

        ITokenManager tokenManager = tadleFactory.getTokenManager();
        tokenManager.addTokenBalance(
            TokenBalanceType.MakerRefund,
            _msgSender(),
            makerInfo.tokenAddress,
            makerRefundAmount
        );

        //q- What can the aborted Status lead into.
        offerInfo.abortOfferStatus = AbortOfferStatus.Aborted;
        offerInfo.offerStatus = OfferStatus.Settled;

        emit AbortAskOffer(_offer, _msgSender());
    }

    /**
     * @notice abort bid taker
     * @param _stock stock address
     * @param _offer offer address
     * @notice Only offer owner can abort bid taker
     * @dev Only offer abort status is aborted can be aborted
     * @dev Update stock authority refund amount
     */
    function abortBidTaker(address _stock, address _offer) external {
        StockInfo storage stockInfo = stockInfoMap[_stock];
        OfferInfo storage preOfferInfo = offerInfoMap[_offer];

        if (stockInfo.authority != _msgSender()) {
            revert Errors.Unauthorized();
        }

        //q- why is this different from above?
        if (stockInfo.preOffer != _offer) {
            revert InvalidOfferAccount(stockInfo.preOffer, _offer);
        }

        if (stockInfo.stockStatus != StockStatus.Initialized) {
            revert InvalidStockStatus(
                StockStatus.Initialized,
                stockInfo.stockStatus
            );
        }

        if (preOfferInfo.abortOfferStatus != AbortOfferStatus.Aborted) {
            revert InvalidAbortOfferStatus(
                AbortOfferStatus.Aborted,
                preOfferInfo.abortOfferStatus
            );
        }

        //Using our previous example, I how have stock worth 100 points.
        //My deposit amount is 100 * 1000 / 500 = 200, this doesn't seem like it makes sense

        //Our deposit amount should be 500 * 100 /1000 which is 50. If there are a total of 1000 points with amount 500
        //and we bought 100 points (1/10) we should have paid 50 for it.
        
        //@audit incorrect calculation.
        uint256 depositAmount = stockInfo.points.mulDiv(
            preOfferInfo.points,
            preOfferInfo.amount,
            Math.Rounding.Floor
        );

        uint256 transferAmount = OfferLibraries.getDepositAmount(
            preOfferInfo.offerType,
            preOfferInfo.collateralRate,
            depositAmount,
            false,
            Math.Rounding.Floor
        );

        MakerInfo storage makerInfo = makerInfoMap[preOfferInfo.maker];
        ITokenManager tokenManager = tadleFactory.getTokenManager();
        tokenManager.addTokenBalance(
            TokenBalanceType.MakerRefund,
            _msgSender(),
            makerInfo.tokenAddress,
            transferAmount
        );

        stockInfo.stockStatus = StockStatus.Finished;

        emit AbortBidTaker(_offer, _msgSender());
    }

    /**
     * @dev Update offer status
     * @notice Only called by DeliveryPlace
     * @param _offer offer address
     * @param _status new status
     */
    function updateOfferStatus(
        address _offer,
        OfferStatus _status
    ) external onlyDeliveryPlace(tadleFactory, _msgSender()) {
        OfferInfo storage offerInfo = offerInfoMap[_offer];
        offerInfo.offerStatus = _status;

        emit OfferStatusUpdated(_offer, _status);
    }

    /**
     * @dev Update stock status
     * @notice Only called by DeliveryPlace
     * @param _stock stock address
     * @param _status new status
     */
    function updateStockStatus(
        address _stock,
        StockStatus _status
    ) external onlyDeliveryPlace(tadleFactory, _msgSender()) {
        StockInfo storage stockInfo = stockInfoMap[_stock];
        stockInfo.stockStatus = _status;

        emit StockStatusUpdated(_stock, _status);
    }

    /**
     * @dev Settled ask offer
     * @notice Only called by DeliveryPlace
     * @param _offer offer address
     * @param _settledPoints settled points
     * @param _settledPointTokenAmount settled point token amount
     */
    function settledAskOffer(
        address _offer,
        uint256 _settledPoints,
        uint256 _settledPointTokenAmount
    ) external onlyDeliveryPlace(tadleFactory, _msgSender()) {
        OfferInfo storage offerInfo = offerInfoMap[_offer];
        offerInfo.settledPoints = _settledPoints;
        offerInfo.settledPointTokenAmount = _settledPointTokenAmount;
        offerInfo.offerStatus = OfferStatus.Settled;

        emit SettledAskOffer(_offer, _settledPoints, _settledPointTokenAmount);
    }

    /**
     * @dev Settle ask taker
     * @notice Only called by DeliveryPlace
     * @param _offer offer address
     * @param _stock stock address
     * @param _settledPoints settled points
     * @param _settledPointTokenAmount settled point token amount
     */
    function settleAskTaker(
        address _offer,
        address _stock,
        uint256 _settledPoints,
        uint256 _settledPointTokenAmount
    ) external onlyDeliveryPlace(tadleFactory, _msgSender()) {
        StockInfo storage stockInfo = stockInfoMap[_stock];
        OfferInfo storage offerInfo = offerInfoMap[_offer];

        offerInfo.settledPoints = offerInfo.settledPoints + _settledPoints;
        offerInfo.settledPointTokenAmount =
            offerInfo.settledPointTokenAmount +
            _settledPointTokenAmount;

        stockInfo.stockStatus = StockStatus.Finished;

        //@audit- No Update to stock.points here
        emit SettledBidTaker(
            _offer,
            _stock,
            _settledPoints,
            _settledPointTokenAmount
        );
    }

    /**
     * @dev Get offer info by offer address
     * @param _offer offer address
     */
    function getOfferInfo(
        address _offer
    ) external view returns (OfferInfo memory _offerInfo) {
        return offerInfoMap[_offer];
    }

    /**
     * @dev Get stock info by stock address
     * @param _stock stock address
     */
    function getStockInfo(
        address _stock
    ) external view returns (StockInfo memory _stockInfo) {
        return stockInfoMap[_stock];
    }

    /**
     * @dev Get maker info by maker address
     * @param _maker maker address
     */
    function getMakerInfo(
        address _maker
    ) external view returns (MakerInfo memory _makerInfo) {
        return makerInfoMap[_maker];
    }

    function _depositTokenWhenCreateTaker(
        uint256 platformFee,
        uint256 depositAmount,
        uint256 tradeTax,
        MakerInfo storage makerInfo,
        OfferInfo storage offerInfo,
        ITokenManager tokenManager
    ) internal {
        uint256 transferAmount = OfferLibraries.getDepositAmount(
            offerInfo.offerType,
            offerInfo.collateralRate,
            depositAmount,
            false,
            Math.Rounding.Ceil
        );

        transferAmount = transferAmount + platformFee + tradeTax;

        tokenManager.tillIn{value: msg.value}(
            _msgSender(),
            makerInfo.tokenAddress,
            transferAmount,
            false
        );
    }

    function _updateReferralBonus(
        uint256 platformFee,
        uint256 depositAmount,
        address stockAddr,
        MakerInfo storage makerInfo,
        ReferralInfo memory referralInfo,
        ITokenManager tokenManager
    ) internal returns (uint256 remainingPlatformFee) {
        if (referralInfo.referrer == address(0x0)) {
            remainingPlatformFee = platformFee;
        } else {
            /**
             * @dev calculate referrer referral bonus and authority referral bonus
             * @dev calculate remaining platform fee
             * @dev remaining platform fee = platform fee - referrer referral bonus - authority referral bonus
             * @dev referrer referral bonus = platform fee * referrer rate
             * @dev authority referral bonus = platform fee * authority rate
             * @dev emit ReferralBonus
             */


             //ok so the referrer referral bonus how much we get froms someone else's trade

            //The authority referral bonus is how much of our own bonus we decide to refund to the person we referred.

            //The referral bonus is 30% of the platform fee. We can to allocate a certain amount of this bonus to the referrer and the rest to the authority.

            //q- Theres no check our referrerRate or authority rate doesn't exceed the base referral rate.
            uint256 referrerReferralBonus = platformFee.mulDiv(
                referralInfo.referrerRate,
                Constants.REFERRAL_RATE_DECIMAL_SCALER,
                Math.Rounding.Floor
            );

            /**
             * @dev update referrer referral bonus
             * @dev update authority referral bonus
             */
            tokenManager.addTokenBalance(
                TokenBalanceType.ReferralBonus,
                referralInfo.referrer,
                makerInfo.tokenAddress,
                referrerReferralBonus
            );

            uint256 authorityReferralBonus = platformFee.mulDiv(
                referralInfo.authorityRate,
                Constants.REFERRAL_RATE_DECIMAL_SCALER,
                Math.Rounding.Floor
            );

            tokenManager.addTokenBalance(
                TokenBalanceType.ReferralBonus,
                _msgSender(),
                makerInfo.tokenAddress,
                authorityReferralBonus
            );

            remainingPlatformFee =
                platformFee -
                referrerReferralBonus -
                authorityReferralBonus;

            /// @dev emit ReferralBonus
            emit ReferralBonus(
                stockAddr,
                _msgSender(),
                referralInfo.referrer,
                authorityReferralBonus,
                referrerReferralBonus,
                depositAmount,
                platformFee
            );
        }
    }

    function _updateTokenBalanceWhenCreateTaker(
        address _offer,
        uint256 _tradeTax,
        uint256 _depositAmount,
        OfferInfo storage offerInfo,
        MakerInfo storage makerInfo,
        ITokenManager tokenManager
    ) internal {
        if (
            _offer == makerInfo.originOffer ||
            makerInfo.offerSettleType == OfferSettleType.Protected
        ) {
            tokenManager.addTokenBalance(
                TokenBalanceType.TaxIncome,
                offerInfo.authority,
                makerInfo.tokenAddress,
                _tradeTax
            );
        } else {
            tokenManager.addTokenBalance(
                TokenBalanceType.TaxIncome,
                makerInfo.authority,
                makerInfo.tokenAddress,
                _tradeTax
            );
        }

        /// @dev update sales revenue
        if (offerInfo.offerType == OfferType.Ask) {
            tokenManager.addTokenBalance(
                TokenBalanceType.SalesRevenue,
                offerInfo.authority, //Update revenue of who bought the stock
                makerInfo.tokenAddress,
                _depositAmount
            );
        } else {
            tokenManager.addTokenBalance(
                TokenBalanceType.SalesRevenue,
                _msgSender(), //Update revenue of this contract
                makerInfo.tokenAddress,
                _depositAmount
            );
        }
    }
}
