// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IIncomeManager.sol";
import "../interfaces/IAtmosStake.sol";
import "../interfaces/IAtmosERC20.sol";
import "../common/AtmosProtocol.sol";
import "../common/RunExchange.sol";

import "../interfaces/IUniswapV2Router.sol";
import "../interfaces/IFirebirdRouter.sol";

contract IncomeManager is
    IIncomeManager,
    AtmosProtocol,
    Initializable,
    RunExchange
{
    using SafeERC20 for IAtmosERC20;
    using SafeERC20 for IERC20;

    IAtmosERC20 public atm;
    IAtmosERC20 public ausd;
    IERC20 public weth;
    IERC20 public usdc;
    IAtmosStake public atmStake;

    uint256 public burnRate;

    event LogConvert(
        uint256 atmFromFarm,
        uint256 usdcFromArb,
        uint256 atmFromArb,
        uint256 ausdFromFee,
        uint256 usdcFromFee,
        uint256 atmFromFee,
        uint256 wethFromInvest,
        uint256 usdcFromInvest,
        uint256 atmFromInvest,
        uint256 totalAtm
    );
    event LogDistributeStake(uint256 distributeAmount, uint256 burnAmount);
    event LogSetAtmStake(address atmStake);
    event LogSetBurnRate(uint256 burnRate);

    function init(
        address _atm,
        address _ausd,
        address _atmStake,
        address _exchangeProvider,
        address _usdc,
        address _weth
    ) external initializer onlyOwner {
        atm = IAtmosERC20(_atm);
        ausd = IAtmosERC20(_ausd);
        atmStake = IAtmosStake(_atmStake);

        weth = IERC20(_weth);
        usdc = IERC20(_usdc);

        setExchangeProvider(_exchangeProvider);
        setBurnRate((RATIO_PRECISION * 20) / 100); // 20%
    }

    function convert() external onlyOwnerOrOperator nonReentrant {
        // InitialAtm is the profit from Farm penalty
        uint256 _atmFromFarm = atm.balanceOf(address(this));

        // InitialUsdc is the profit from Arbitrager
        uint256 _usdcFromArb = usdc.balanceOf(address(this));
        if (_usdcFromArb > 0) {
            usdc.safeApprove(address(exchangeProvider), 0);
            usdc.safeApprove(address(exchangeProvider), _usdcFromArb);
            exchangeProvider.swapUsdcToAtm(_usdcFromArb, 0);
        }
        uint256 _atmAfterArb = atm.balanceOf(address(this));
        uint256 _atmFromArb = _atmAfterArb - _atmFromFarm;

        // Initial aUSD is the profit from Bank fee
        uint256 _ausdFromFee = ausd.balanceOf(address(this));
        uint256 _usdcFromFee = 0;
        if (_ausdFromFee > 0) {
            ausd.safeApprove(address(exchangeProvider), 0);
            ausd.safeApprove(address(exchangeProvider), _ausdFromFee);
            exchangeProvider.swapAusdToUsdc(_ausdFromFee, 0);

            _usdcFromFee = usdc.balanceOf(address(this));
            usdc.safeApprove(address(exchangeProvider), 0);
            usdc.safeApprove(address(exchangeProvider), _usdcFromFee);
            exchangeProvider.swapUsdcToAtm(_usdcFromFee, 0);
        }
        uint256 _atmAfterFee = atm.balanceOf(address(this));
        uint256 _atmFromFee = _atmAfterFee - _atmAfterArb;

        // Initial WETH is the profit from Invest
        uint256 _wethFromInvest = weth.balanceOf(address(this));
        uint256 _usdcFromInvest = 0;
        if (_wethFromInvest > 0) {
            weth.safeApprove(address(exchangeProvider), 0);
            weth.safeApprove(address(exchangeProvider), _wethFromInvest);
            exchangeProvider.swapWethToUsdc(_wethFromInvest, 0);

            _usdcFromInvest = usdc.balanceOf(address(this));
            usdc.safeApprove(address(exchangeProvider), 0);
            usdc.safeApprove(address(exchangeProvider), _usdcFromInvest);
            exchangeProvider.swapUsdcToAtm(_usdcFromInvest, 0);
        }
        uint256 _atmAfterInvest = atm.balanceOf(address(this));
        uint256 _atmFromInvest = _atmAfterInvest - _atmAfterFee;

        emit LogConvert(
            _atmFromFarm, //
            _usdcFromArb, // Arbitrager
            _atmFromArb, //
            _ausdFromFee,   //
            _usdcFromFee, // Fee
            _atmFromFee, //
            _wethFromInvest, //
            _usdcFromInvest, // Invest
            _atmFromInvest, //
            _atmAfterInvest //
        );
    }

    function distributeStake(uint256 _amount)
        external
        override
        onlyOwnerOrOperator
    {
        require(_amount > 0, "Amount must be greater than 0");

        uint256 _actualAmt = Math.min(atm.balanceOf(address(this)), _amount);
        uint256 _amtToBurn = (_actualAmt * burnRate) / RATIO_PRECISION;

        uint256 _distributeAmt = _actualAmt - _amtToBurn;
        if (_amtToBurn > 0) {
            atm.burn(address(this), _amtToBurn);
        }

        atm.safeApprove(address(atmStake), 0);
        atm.safeApprove(address(atmStake), _distributeAmt);
        atmStake.distribute(_distributeAmt);

        emit LogDistributeStake(_distributeAmt, _amtToBurn);
    }

    function setAtmStake(address _atmStake) public onlyOwner {
        require(_atmStake != address(0), "Invalid address");
        atmStake = IAtmosStake(_atmStake);
        emit LogSetAtmStake(_atmStake);
    }

    function setBurnRate(uint256 _burnRate) public onlyOwnerOrOperator {
        burnRate = _burnRate;
        emit LogSetBurnRate(burnRate);
    }

    function transferTo(
        address _receiver,
        address _token,
        uint256 _amount
    ) public onlyOwner {
        IERC20 token = IERC20(_token);
        require(
            token.balanceOf(address(this)) >= _amount,
            "Not enough balance"
        );
        require(_amount > 0, "Zero amount");
        token.safeTransfer(_receiver, _amount);
    }

    function rescueFund(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
