// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV2Router.sol";

import "../common/AtmosProtocol.sol";
import "../common/RunExchange.sol";
import "../interfaces/ICollector.sol";
import "../libraries/Babylonian.sol";
import "hardhat/console.sol";

contract Arbitrager is AtmosProtocol, RunExchange {
    using SafeERC20 for IERC20;

    ICollector public collector;
    IERC20 public collat;
    IERC20 public ausd;
    IERC20 public atm;
    address public incomeManager;
    IUniswapV2Pair public ausdPair;
    IUniswapV2Pair public pool;

    uint256 private swapFee;
    uint256 public repayFee = 4;

    uint256 private targetHighPrice;
    uint256 private targetLowPrice;

    struct FlashCallbackData {
        uint256 usdcAmt;
        bool isBuy;
    }

    event LogSetContracts(
        address collector,
        address collat,
        address ausd,
        address atm,
        address incomeManager,
        address ausdPair
    );
    event LogSetTargetBand(uint256 targetHighPrice, uint256 targetLowPrice);
    event LogSetSwapFee(uint256 swapFee);
    event LogTrade(
        uint256 initialUsdc,
        uint256 profit,
        bool indexed isBuy
    );

    constructor(
        address _collector,
        address _collat,
        address _ausd,
        address _atm,
        address _incomeManager,
        address _ausdPair,
        address _exchangeProvider,
        address _pool
    ) {
        setContracts(
            _collector,
            _collat,
            _ausd,
            _atm,
            _incomeManager,
            _ausdPair,
            _pool
        );
        uint256 _highBand = (PRICE_PRECISION * 0) / 10000; // 0.45%
        uint256 _lowBand = (PRICE_PRECISION * 0) / 10000; // 0.4%
        setTargetBand(_lowBand, _highBand);
        setSwapFee((SWAP_FEE_PRECISION * 2) / 1000); // 0.2%

        setExchangeProvider(_exchangeProvider);
    }

    function setContracts(
        address _collector,
        address _collat,
        address _ausd,
        address _atm,
        address _incomeManager,
        address _ausdPair,
        address _pool
    ) public onlyOwner {
        collector = _collector != address(0) ? ICollector(_collector) : collector;
        collat = _collat != address(0) ? IERC20(_collat) : collat;
        ausd = _ausd != address(0) ? IERC20(_ausd) : ausd;
        atm = _atm != address(0) ? IERC20(_atm) : atm;
        incomeManager = _incomeManager != address(0) ? _incomeManager : incomeManager;
        ausdPair = _ausdPair != address(0) ? IUniswapV2Pair(_ausdPair) : ausdPair;
        pool = IUniswapV2Pair(_pool);

        emit LogSetContracts(
            address(collector),
            address(collat),
            address(ausd),
            address(atm),
            incomeManager,
            address(ausdPair)
        );
    }

    function setTargetBand(uint256 _lowBand, uint256 _highBand)
    public
    onlyOwnerOrOperator
    {
        targetHighPrice = PRICE_PRECISION + _highBand;
        targetLowPrice = PRICE_PRECISION - _lowBand;
        emit LogSetTargetBand(targetHighPrice, targetLowPrice);
    }

    function setSwapFee(uint256 _swapFee) public onlyOwnerOrOperator {
        swapFee = _swapFee;
        emit LogSetSwapFee(swapFee);
    }

    function setRepayFee(uint256 _fee) public onlyOwnerOrOperator {
        repayFee = _fee;
    }


    function uniswapV2Call(address , uint , uint , bytes calldata data) external {
        require(
            msg.sender == address(pool),
            "Arbitrager: sender not pool"
        );

        FlashCallbackData memory decoded = abi.decode(
            data,
            (FlashCallbackData)
        );

        if (decoded.isBuy) {
            // Buy aUSD
            _buyAusd(decoded.usdcAmt);
        } else {
            // Sell aUSD
            _sellAusd(decoded.usdcAmt);
        }
      
        // Assert profit
        uint256 fee = decoded.usdcAmt * repayFee / 1000;
        uint256 _usdcOwed = decoded.usdcAmt + fee;
        uint256 _balanceAfter = collat.balanceOf(address(this));
        require(_balanceAfter > _usdcOwed, "Arbitrager: Minus profit");

        uint256 _profit = _balanceAfter - _usdcOwed;

        // Repay
        collat.safeTransfer(address(pool), _usdcOwed);

        // Send profit to Profit Handler
        collat.safeTransfer(incomeManager, _profit);

        emit LogTrade(decoded.usdcAmt, _profit, decoded.isBuy);
    }

    function buyAusd() external onlyOwnerOrOperator {
        uint256 _rsvAusd = 0;
        uint256 _rsvUsdc = 0;
        if (address(ausd) <= address(collat)) {
            (_rsvAusd, _rsvUsdc, ) = ausdPair.getReserves();
        } else {
            (_rsvUsdc, _rsvAusd, ) = ausdPair.getReserves();
        }

        uint256 _usdcAmt = _calcUsdcAmtToBuy(_rsvUsdc, _rsvAusd);

        _usdcAmt =
        (_usdcAmt * SWAP_FEE_PRECISION) /
        (SWAP_FEE_PRECISION - swapFee);


        pool.swap(
            0,
            _usdcAmt,
            address(this),
            abi.encode(FlashCallbackData({usdcAmt: _usdcAmt, isBuy: true}))
        );

    }

    function _buyAusd(uint256 _usdcAmt) internal {

        // buy aUSD
        collat.safeApprove(address(exchangeProvider), 0);
        collat.safeApprove(address(exchangeProvider), _usdcAmt);

        exchangeProvider.swapUsdcToAusd(_usdcAmt, 0);
        
        // redeem aUSD
        uint256 _ausdAmount = ausd.balanceOf(address(this));
        ausd.safeApprove(address(collector), 0);
        ausd.safeApprove(address(collector), _ausdAmount);
        collector.arbRedeem(_ausdAmount);

        // sell ATM
        uint256 _atmAmount = atm.balanceOf(address(this));
        if (_atmAmount > 0) {
            atm.safeApprove(address(exchangeProvider), 0);
            atm.safeApprove(address(exchangeProvider), _atmAmount);
            exchangeProvider.swapAtmToUsdc(_atmAmount, 0);
        }
    }

    function _calcUsdcAmtToBuy(uint256 _rsvUsdc, uint256 _rsvAusd)
    internal
    view
    returns (uint256)
    {
        // Buying aUSD means we want to increase the aUSD price to targetLowPrice
        uint256 _y = ((targetLowPrice * _rsvUsdc * _rsvAusd) /
        AUSD_PRECISION);

        return Babylonian.sqrt(_y) - _rsvUsdc;
    }

    function sellAusd() external onlyOwnerOrOperator {
        uint256 _rsvAusd = 0;
        uint256 _rsvUsdc = 0;
        if (address(ausd) <= address(collat)) {
            (_rsvAusd, _rsvUsdc, ) = ausdPair.getReserves();
        } else {
            (_rsvUsdc, _rsvAusd, ) = ausdPair.getReserves();
        }

        uint256 _ausdAmt = _calcAusdAmtToSell(_rsvUsdc, _rsvAusd);
        uint256 _usdcAmt = (_ausdAmt * SWAP_FEE_PRECISION) /
        (SWAP_FEE_PRECISION - swapFee) /
        MISSING_PRECISION;


        console.log("usdc amt: ", _usdcAmt);

        pool.swap(
            0,
            _usdcAmt,
            address(this),
            abi.encode(FlashCallbackData({usdcAmt: _usdcAmt, isBuy: false}))
        );
    }

    function _sellAusd(uint256 _usdcAmt) internal {

        // mint aUSD to sell
        collat.safeApprove(address(collector), 0);
        collat.safeApprove(address(collector), _usdcAmt);

        uint256 bal = collat.balanceOf(address(this));

        console.log("Arbitrager usdc balance: ", bal);

        collector.arbMint(_usdcAmt);

        // sell aUSD for USDC
        uint256 _ausdAmt = ausd.balanceOf(address(this));
        ausd.safeApprove(address(exchangeProvider), 0);
        ausd.safeApprove(address(exchangeProvider), _ausdAmt);
        exchangeProvider.swapAusdToUsdc(_ausdAmt, 0);
    }

    function _calcAusdAmtToSell(uint256 _rsvUsdc, uint256 _rsvAusd)
    internal
    view
    returns (uint256)
    {
        // Selling aUSD means we want to decrease the aUSD price to targetHighPrice
        uint256 _y = ((_rsvAusd * _rsvUsdc * targetHighPrice) *
        AUSD_PRECISION) /
        PRICE_PRECISION /
        PRICE_PRECISION;

        uint256 _result = ((Babylonian.sqrt(_y) * PRICE_PRECISION) /
        targetHighPrice) - _rsvAusd;

        return _result;
    }
}