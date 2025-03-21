// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DeliveryPlaceStorage} from "../storage/DeliveryPlaceStorage.sol";
import {OfferStatus, StockStatus, OfferType, StockType, OfferSettleType} from "../storage/OfferStatus.sol";
import {ITadleFactory} from "../factory/ITadleFactory.sol";
import {IDeliveryPlace} from "../interfaces/IDeliveryPlace.sol";
import {ISystemConfig, MarketPlaceInfo, MarketPlaceStatus} from "../interfaces/ISystemConfig.sol";
import {IPerMarkets, OfferInfo, StockInfo, MakerInfo} from "../interfaces/IPerMarkets.sol";
import {TokenBalanceType, ITokenManager} from "../interfaces/ITokenManager.sol";
import {RelatedContractLibraries} from "../libraries/RelatedContractLibraries.sol";
import {MarketPlaceLibraries} from "../libraries/MarketPlaceLibraries.sol";
import {OfferLibraries} from "../libraries/OfferLibraries.sol";
import {Rescuable} from "../utils/Rescuable.sol";
import {Errors} from "../utils/Errors.sol";

/**
 * @title DeliveryPlace
 * @notice Implement the delivery place
 */
contract DeliveryPlace is DeliveryPlaceStorage, Rescuable, IDeliveryPlace {
    using Math for uint256;
    using RelatedContractLibraries for ITadleFactory;

    constructor() Rescuable() {}

    /**
     * @notice Close bid offer
     * @dev caller must be offer authority
     * @dev offer type must Bid
     * @dev offer status must be Settling
     * @dev refund amount = offer amount - used amount
     */

    //We created an offer to buy points and now we want to close it.
    //This should really be renamed to settleBidOffer
    function closeBidOffer(address _offer) external {
        (
            OfferInfo memory offerInfo,
            MakerInfo memory makerInfo,
            ,
            MarketPlaceStatus status
        ) = getOfferInfo(_offer);

        if (_msgSender() != offerInfo.authority) {
            revert Errors.Unauthorized();
        }

        if (offerInfo.offerType == OfferType.Ask) {
            revert InvalidOfferType(OfferType.Bid, OfferType.Ask);
        }

        if (
            status != MarketPlaceStatus.AskSettling &&
            status != MarketPlaceStatus.BidSettling
        ) {
            revert InvaildMarketPlaceStatus();
        }

        //@audit - This shouldn't exists it prevents partial refunds,
        //that the blow code seems to be ok with.
        if (offerInfo.offerStatus != OfferStatus.Virgin) {
            revert InvalidOfferStatus();
        }

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

        IPerMarkets perMarkets = tadleFactory.getPerMarkets();
        perMarkets.updateOfferStatus(_offer, OfferStatus.Settled);

        //@audit- where is the settledBidOffer function?

        emit CloseBidOffer(
            makerInfo.marketPlace,
            offerInfo.maker,
            _offer,
            _msgSender()
        );
    }

    /**
     * @notice Close bid taker
     * @dev caller must be stock authority
     * @dev stock type must Bid
     * @dev offer status must be Settled
     * @param _stock stock address
     */

     //So I think the idea of this function is that not all points were settled
     //at TGE, so now the bidder is looking to claim back some of his cash using the makers
     //collateral. We need the makers collateral, how many points of the bidder were settled, and total
     //points

    function closeBidTaker(address _stock) external {
        IPerMarkets perMarkets = tadleFactory.getPerMarkets();
        ITokenManager tokenManager = tadleFactory.getTokenManager();
        StockInfo memory stockInfo = perMarkets.getStockInfo(_stock);

        if (stockInfo.preOffer == address(0x0)) {
            revert InvalidStock();
        }

        //So our stockType is bid, meaning we bought some offer or created an offer.
        //A stocktype of bid represents a buyers position.
        if (stockInfo.stockType == StockType.Ask) {
            revert InvalidStockType();
        }

        if (_msgSender() != stockInfo.authority) {
            revert Errors.Unauthorized();
        }

        (
            OfferInfo memory preOfferInfo,
            MakerInfo memory makerInfo,
            ,

        ) = getOfferInfo(stockInfo.preOffer);

        OfferInfo memory offerInfo;
        uint256 userRemainingPoints;
        if (makerInfo.offerSettleType == OfferSettleType.Protected) {
            offerInfo = preOfferInfo;
            userRemainingPoints = stockInfo.points;
        } else {
            offerInfo = perMarkets.getOfferInfo(makerInfo.originOffer);
            //we haven't tried to sell the stock we bought
            if (stockInfo.offer == address(0x0)) {
                userRemainingPoints = stockInfo.points;
            } else {
                //we decided to list the stock we bought
                OfferInfo memory listOfferInfo = perMarkets.getOfferInfo(
                    stockInfo.offer
                );
                //@audit this is wrong.
                //Suppose Alice is our original maker who has a sell offer for 1000 points
                //Suppose Bob buys 500 points from Alice
                //Bob then goes to list 300 of the 500 points he bought from alice (listOffer.points = 300)
                //suppose cathy buys 100 of bobs points, so now bobs points is 300 and usedPoints is 100
                //(listOffer.points = 300, listOffer.usedPoints = 100)
                //The below says bobs remaningPoints is 
                //listOffer.points - usedPoints = 300 - 100 = 200, BUT bob still has 200 unlisted points.
                //so 200 of bobs points are not taken into account.
                //https://chatgpt.com/share/67dd7114-adfc-800d-85ff-06540f491955
                //(1/7)     

                //This should be something like stock.points - listOfferInfo.usedPoints

                userRemainingPoints =
                    listOfferInfo.points -
                    listOfferInfo.usedPoints;
            }
        }

        if (userRemainingPoints == 0) {
            revert InsufficientRemainingPoints();
        }

        if (offerInfo.offerStatus != OfferStatus.Settled) {
            revert InvalidOfferStatus();
        }

        if (stockInfo.stockStatus != StockStatus.Initialized) {
            revert InvalidStockStatus();
        }

        uint256 collateralFee;

        //q- This is saying that of our used points not all of them were settled at TGE.
        if (offerInfo.usedPoints > offerInfo.settledPoints) {
            //q wait what wer revert when offerStatus is not settled so this branch
            //will never be reached.
            if (offerInfo.offerStatus == OfferStatus.Virgin) {
                collateralFee = OfferLibraries.getDepositAmount(
                    offerInfo.offerType,
                    offerInfo.collateralRate,
                    offerInfo.amount,
                    true,
                    Math.Rounding.Floor
                );
            } else {
                //1st case
                //lets say that amount is $500 and used points is 100 and total points is 1000

                //2nd case (2 people bid, and someone already bid 100 points, and now a new person is bidding 100)
                //amount is $500 usedPoints is 200 and totalAmount is 1000, usedAmount = 100 
                uint256 usedAmount = offerInfo.amount.mulDiv(
                    offerInfo.usedPoints,
                    offerInfo.points,
                    Math.Rounding.Floor
                );
                //fee == usdeAmount * CollaterateRate = 50 * 1.2 = 60

                //case 2, fee == 100 * 1.2 = 120
                collateralFee = OfferLibraries.getDepositAmount(
                    offerInfo.offerType, //Ask
                    offerInfo.collateralRate,
                    usedAmount,
                    true,
                    Math.Rounding.Floor
                );
            }
        }

        //first case
        //60 * 100 / 100 = 60
        //THis makes sense, with an amount of 500 and a collateral rate of 1.2
        //the user must have deposited $600 worth of funds. If we have 1000 points,
        //and a user buys 100 of those points they should be entitled to 10% of our collateral.
        //which is 60. For the cases in which only 1 person buys points this makes sense lets test 2.

        //2nd case (2 deposits), userCOllateral = 120 * 100/200 = 60, still good.

        uint256 userCollateralFee = collateralFee.mulDiv(
            userRemainingPoints,
            offerInfo.usedPoints,
            Math.Rounding.Floor
        );

        tokenManager.addTokenBalance(
            TokenBalanceType.RemainingCash,
            _msgSender(),
            makerInfo.tokenAddress,
            userCollateralFee
        );
        

        //q- Not sure about this
        uint256 pointTokenAmount = offerInfo.settledPointTokenAmount.mulDiv(
            userRemainingPoints,
            offerInfo.usedPoints,
            Math.Rounding.Floor
        );
        tokenManager.addTokenBalance(
            TokenBalanceType.PointToken,
            _msgSender(),
            makerInfo.tokenAddress,
            pointTokenAmount
        );

        //stock brought into finished cuz we've claimed collateral
        perMarkets.updateStockStatus(_stock, StockStatus.Finished);

        //@audit- we don't close any potential open offers
        emit CloseBidTaker(
            makerInfo.marketPlace,
            offerInfo.maker,
            _stock,
            _msgSender(),
            userCollateralFee,
            pointTokenAmount
        );
    }

    /**
     * @notice Settle ask maker
     * @dev caller must be offer authority
     * @dev offer status must be Virgin or Canceled
     * @dev market place status must be AskSettling
     * @param _offer offer address
     * @param _settledPoints settled points
     */

    //We deposited collateral to sell, now depending on how many points we settle we recieve our collateral back
    function settleAskMaker(address _offer, uint256 _settledPoints) external {
        (
            OfferInfo memory offerInfo,
            MakerInfo memory makerInfo,
            MarketPlaceInfo memory marketPlaceInfo,
            MarketPlaceStatus status
        ) = getOfferInfo(_offer);

        if (_settledPoints > offerInfo.usedPoints) {
            revert InvalidPoints();
        }

        //@audit- No check for settledPoints == offer.settledPoints

        if (marketPlaceInfo.fixedratio) {
            revert FixedRatioUnsupported();
        }

        //This function is for if we have a sell offer.
        if (offerInfo.offerType == OfferType.Bid) {
            revert InvalidOfferType(OfferType.Ask, OfferType.Bid);
        }

        if (
            offerInfo.offerStatus != OfferStatus.Virgin &&
            offerInfo.offerStatus != OfferStatus.Canceled
        ) {
            revert InvalidOfferStatus();
        }

        if (status == MarketPlaceStatus.AskSettling) {
            if (_msgSender() != offerInfo.authority) {
                revert Errors.Unauthorized();
            }
        } else {
            if (_msgSender() != owner()) {
                revert Errors.Unauthorized();
            }
            if (_settledPoints > 0) {
                revert InvalidPoints();
            }
        }

        uint256 settledPointTokenAmount = marketPlaceInfo.tokenPerPoint *
            _settledPoints;

        ITokenManager tokenManager = tadleFactory.getTokenManager();
        if (settledPointTokenAmount > 0) {
            //q- Why are we not passing in msg.value here?
            //q- Why are we still sending money to the capitalPool if we're settling
            //ask Maker
            //a- Ok so each offer has points and we are seelling those points. Once we've settled these points
            //the settledPoints on our offer is udpated, this is sending the money from those settledPoints

            //q- New questiosn then, why are we not just getting the settledPoints from the offer?

            //a- The maker decides how much they want to settle then send that amount to the capital pool,
            //the rest is collateral for others to claim.
            tokenManager.tillIn(
                _msgSender(),
                marketPlaceInfo.tokenAddress,
                settledPointTokenAmount,
                true
            );
        }

        uint256 makerRefundAmount;
        //@audit- PartialSettlements don't work, because we only check if 
        //settledPoints == offerInfo.usedPoints
        if (_settledPoints == offerInfo.usedPoints) {
            if (offerInfo.offerStatus == OfferStatus.Virgin) {
                //Set Refund to our collateral if we had no buyers
                makerRefundAmount = OfferLibraries.getDepositAmount(
                    offerInfo.offerType,
                    offerInfo.collateralRate,
                    offerInfo.amount,
                    true,
                    Math.Rounding.Floor
                );
            } else {
                //500 * 100/1000 = 50
                uint256 usedAmount = offerInfo.amount.mulDiv(
                    offerInfo.usedPoints,
                    offerInfo.points,
                    Math.Rounding.Floor
                );
                //50 * 1.2 = 60

                //so we refund based on the amount we setteld.
                makerRefundAmount = OfferLibraries.getDepositAmount(
                    offerInfo.offerType,
                    offerInfo.collateralRate,
                    usedAmount,
                    true,
                    Math.Rounding.Floor
                );
            }

            tokenManager.addTokenBalance(
                TokenBalanceType.SalesRevenue, //@audit- TokenBalanceType should be makerRefund
                _msgSender(),
                makerInfo.tokenAddress,
                makerRefundAmount
            );
        }

        IPerMarkets perMarkets = tadleFactory.getPerMarkets();
        perMarkets.settledAskOffer(
            _offer,
            _settledPoints,
            settledPointTokenAmount
        );

        emit SettleAskMaker(
            makerInfo.marketPlace,
            offerInfo.maker,
            _offer,
            _msgSender(), //@audit- In cases where owner sends this authority is not msgSender
            _settledPoints,
            settledPointTokenAmount,
            makerRefundAmount
        );
    }

    /**
     * @notice Settle ask taker
     * @dev caller must be stock authority
     * @dev market place status must be AskSettling
     * @param _stock stock address
     * @param _settledPoints settled points
     * @notice _settledPoints must be less than or equal to stock points
     */

     //a stock that we sold, and now we're looking to settle it, and pay the people who bought it.
    function settleAskTaker(address _stock, uint256 _settledPoints) external {
        IPerMarkets perMarkets = tadleFactory.getPerMarkets();
        StockInfo memory stockInfo = perMarkets.getStockInfo(_stock);

        (
            OfferInfo memory offerInfo,
            MakerInfo memory makerInfo,
            MarketPlaceInfo memory marketPlaceInfo,
            MarketPlaceStatus status
        ) = getOfferInfo(stockInfo.preOffer); //@audit - No differentiation between turboMode and protectedMode
        //For turbo mode the offerInfor we get should be makerInfo.originOffer

        if (stockInfo.stockStatus != StockStatus.Initialized) {
            revert InvalidStockStatus();
        }

        if (marketPlaceInfo.fixedratio) {
            revert FixedRatioUnsupported();
        }
        //This function deals with a stockType of Ask, so a sellers position.
        if (stockInfo.stockType == StockType.Bid) {
            revert InvalidStockType();
        }
        if (_settledPoints > stockInfo.points) {
            revert InvalidPoints();
        }

        if (status == MarketPlaceStatus.AskSettling) {
            if (_msgSender() != offerInfo.authority) {
                revert Errors.Unauthorized();
            }
        } else {
            if (_msgSender() != owner()) {
                revert Errors.Unauthorized();
            }
            if (_settledPoints > 0) {
                revert InvalidPoints();
            }
        }

        uint256 settledPointTokenAmount = marketPlaceInfo.tokenPerPoint *
            _settledPoints;
        ITokenManager tokenManager = tadleFactory.getTokenManager();
        if (settledPointTokenAmount > 0) {
            //transfer from msg.sender to capital pool, makese sense
            tokenManager.tillIn(
                _msgSender(), //offerInfo.authority or Owner()
                marketPlaceInfo.tokenAddress,
                settledPointTokenAmount,
                true
            );

            tokenManager.addTokenBalance(
                TokenBalanceType.PointToken,
                offerInfo.authority, //@audit this should be stockInfo.authority
                makerInfo.tokenAddress,
                settledPointTokenAmount
            );
        }

        uint256 collateralFee = OfferLibraries.getDepositAmount(
            offerInfo.offerType, //Bid, (person who bought our stock)
            offerInfo.collateralRate,
            stockInfo.amount, //how much the other person was looking to buy
            false,
            Math.Rounding.Floor
        );
        
        //If we settled all their points, we return our collateral
        if (_settledPoints == stockInfo.points) {
            tokenManager.addTokenBalance(
                TokenBalanceType.RemainingCash,
                _msgSender(), //offerInfo.authority / owner()
                makerInfo.tokenAddress,
                collateralFee
            );
        } else {
           //If we don't settle all the users points, we still refund ourselves our whole collateral?

           //wait the dev of this is either saying that we forfeit our collateral if we don't settle all the users points
           //or this is saying we should refund a portion of our collateral if we don't full settle all the users points.

           //I'm leaning towards the idea that its saying we should refund a portion of our collateral if we don't full settle all the users points.

           //@audit this should not refund us the entire collateral FEE instead it should refund us a portion of the collateralFee based
           //on how much we settle.
            tokenManager.addTokenBalance(
                TokenBalanceType.MakerRefund,
                offerInfo.authority,
                makerInfo.tokenAddress,
                collateralFee
            );
        }

        perMarkets.settleAskTaker(
            stockInfo.preOffer,
            _stock,
            _settledPoints,
            settledPointTokenAmount
        );

        emit SettleAskTaker(
            makerInfo.marketPlace,
            offerInfo.maker,
            _stock,
            stockInfo.preOffer,
            _msgSender(), //@audit - In cases where msgSender is owner() this should be stock.Authority
            _settledPoints,
            settledPointTokenAmount,
            collateralFee
        );
    }

    function getOfferInfo(
        address _offer
    )
        internal
        view
        returns (
            OfferInfo memory offerInfo,
            MakerInfo memory makerInfo,
            MarketPlaceInfo memory marketPlaceInfo,
            MarketPlaceStatus status
        )
    {
        IPerMarkets perMarkets = tadleFactory.getPerMarkets();
        ISystemConfig systemConfig = tadleFactory.getSystemConfig();

        offerInfo = perMarkets.getOfferInfo(_offer);
        makerInfo = perMarkets.getMakerInfo(offerInfo.maker);
        marketPlaceInfo = systemConfig.getMarketPlaceInfo(
            makerInfo.marketPlace
        );

        status = MarketPlaceLibraries.getMarketPlaceStatus(
            block.timestamp,
            marketPlaceInfo
        );
    }
}
