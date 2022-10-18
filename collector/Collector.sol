// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "hardhat/console.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

import "../interfaces/ICollector.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IAtmosERC20.sol";
import "../interfaces/IDepository.sol";
import "../interfaces/IIncomeManager.sol";
import "../common/OnlyArbitrager.sol";
import "../common/RunExchange.sol";
import "../libraries/Babylonian.sol";
import "./CollectorStates.sol";
import "./CollectorRecollatStates.sol";
import "./Depository.sol";
import "./Shredder.sol";

contract Collector is
    ICollector,
    Initializable,
    CollectorStates,
    CollectorRecollatStates,
    OnlyArbitrager,
    RunExchange
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IAtmosERC20;

    // Variables
    IERC20 public collat;
    IAtmosERC20 public ausd;
    IAtmosERC20 public atm;
    IUniswapV2Pair public atmPair;
    IPriceOracle public oracle;
    IDepository public depository;
    IIncomeManager public incomeManager;
    address public shredder;

    uint256 public override tcr = TCR_MAX;
    uint256 public override ecr = tcr;

    mapping(address => uint256) public redeemAtmBal;
    mapping(address => uint256) public redeemCollatBal;
    mapping(address => uint256) public lastRedeemed;
    uint256 public unclaimedAtm;
    uint256 public override unclaimedCollat;

    event CollatStats(uint256 investingAmt, uint256 idleAmt);
    event ArbMint(uint256 collatIn, uint256 ausdOut);
    event ArbRedeem(uint256 ausdIn, uint256 collatOut, uint256 AtmOut);
    event RatioUpdated(uint256 tcr, uint256 ecr);
    event ZapSwapped(uint256 collatAmt, uint256 lpAmount);
    event Recollateralized(uint256 collatIn, uint256 atmOut);
    event LogMint(
        uint256 collatIn,
        uint256 AtmIn,
        uint256 ausdOut,
        uint256 ausdFee
    );
    event LogRedeem(
        uint256 ausdIn,
        uint256 collatOut,
        uint256 ausdOut,
        uint256 ausdFee
    );

    function init(
        address _collat,
        address _ausd,
        address _atm,
        address _atmPair,
        address _oracle,
        address _depository,
        address _shredder,
        address _arbitrager,
        address _incomeManager,
        address _exchangeProvider,
        uint256 _tcr
    ) public initializer onlyOwner {
        require(
            _collat != address(0) &&
                _ausd != address(0) &&
                _atm != address(0) &&
                _oracle != address(0) &&
                _depository != address(0),
            "Collector: invalid address"
        );

        collat = IERC20(_collat);
        ausd = IAtmosERC20(_ausd);
        atm = IAtmosERC20(_atm);
        atmPair = IUniswapV2Pair(_atmPair);
        oracle = IPriceOracle(_oracle);
        depository = IDepository(_depository);
        shredder = _shredder;
        incomeManager = IIncomeManager(_incomeManager);
        tcr = _tcr;
        blockTimestampLast = _currentBlockTs();

        // Init for OnlyArbitrager
        setArbitrager(_arbitrager);

        setExchangeProvider(_exchangeProvider);
    }

    function setContracts(
        address _depository,
        address _shredder,
        address _incomeManager,
        address _oracle
    ) public onlyOwner {
        require(
            _depository != address(0) &&
                _shredder != address(0) &&
                _incomeManager != address(0) &&
                _oracle != address(0),
            "Collector: Address zero"
        );

        depository = IDepository(_depository);
        shredder = _shredder;
        incomeManager = IIncomeManager(_incomeManager);
        oracle = IPriceOracle(_oracle);
    }

    // Public functions
    function calcEcr() public view returns (uint256) {
        if (!enableEcr) {
            return tcr;
        }
        uint256 _totalCollatValueE18 = (totalCollatAmt() *
            MISSING_PRECISION *
            oracle.collatPrice()) / PRICE_PRECISION;

        uint256 _ecr = (_totalCollatValueE18 * RATIO_PRECISION) /
            ausd.totalSupply();
        _ecr = Math.max(_ecr, ecrMin);
        _ecr = Math.min(_ecr, ECR_MAX);

        return _ecr;
    }

    function totalCollatAmt() public view returns (uint256) {
        return
            depository.investingAmt() +
            collat.balanceOf(address(depository)) -
            unclaimedCollat;
    }

    function update() public nonReentrant {
        require(!updatePaused, "Collector: update paused");

        uint64 _timeElapsed = _currentBlockTs() - blockTimestampLast; // Overflow is desired
        require(_timeElapsed >= updatePeriod, "Collector: update too soon");

        uint256 _ausdPrice = oracle.ausdPrice();

        if (_ausdPrice > TARGET_PRICE + priceBand) {
            tcr = Math.max(tcr - tcrMovement, tcrMin);
        } else if (_ausdPrice < TARGET_PRICE - priceBand) {
            tcr = Math.min(tcr + tcrMovement, TCR_MAX);
        }

        ecr = calcEcr();
        blockTimestampLast = _currentBlockTs();
        emit RatioUpdated(tcr, ecr);
    }

    function mint(
        uint256 _collatIn,
        uint256 _atmIn,
        uint256 _ausdOutMin
    ) external onlyNonContract nonReentrant {
        require(!mintPaused, "Collector: mint paused");
        require(_collatIn > 0, "Collector: _collatIn <= 0");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (depository.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Collector: Pool Ceiling"
        );

        uint256 _collatPrice = oracle.collatPrice();
        uint256 _collatValueE18 = (_collatIn *
            MISSING_PRECISION *
            _collatPrice) / PRICE_PRECISION;
        uint256 _ausdOut = (_collatValueE18 * RATIO_PRECISION) / tcr;
        uint256 _requiredAtmAmt = 0;
        uint256 _atmPrice = oracle.atmPrice();



        if (tcr < TCR_MAX) {
            _requiredAtmAmt =
                ((_ausdOut - _collatValueE18) * PRICE_PRECISION) /
                _atmPrice;

        }

        uint256 _ausdFee = (_ausdOut * mintFee) / RATIO_PRECISION;
        _ausdOut = _ausdOut - _ausdFee;
        require(_ausdOut >= _ausdOutMin, "Collector: slippage");

        if (_requiredAtmAmt > 0) {
            require(_atmIn >= _requiredAtmAmt, "Collector: not enough ATM");


            // swap all ATM to ATM/USDC LP
            uint256 _minCollatAmt = (_requiredAtmAmt *
                _atmPrice *
                PRICE_PRECISION *
                (RATIO_PRECISION - zapSlippage)) /
                RATIO_PRECISION /
                PRICE_PRECISION /
                _collatPrice /
                2 /
                MISSING_PRECISION;

            atm.safeTransferFrom(msg.sender, address(this), _requiredAtmAmt);
            atm.safeApprove(address(exchangeProvider), 0);
            atm.safeApprove(address(exchangeProvider), _requiredAtmAmt);

            uint256 _lpAmount = exchangeProvider.zapInAtm(
                _requiredAtmAmt,
                _minCollatAmt,
                0
            );

            // transfer all lp token to Shredder
            IERC20 lpToken = IERC20(address(atmPair));
            lpToken.safeTransfer(shredder, _lpAmount);
        }

        collat.safeTransferFrom(msg.sender, address(depository), _collatIn);
        ausd.mintByCollector(msg.sender, _ausdOut);
        ausd.mintByCollector(address(incomeManager), _ausdFee);
        _collatInfo();
        
        emit LogMint(_collatIn, _atmIn, _ausdOut, _ausdFee);

    }

    function zapMint(uint256 _collatIn, uint256 _ausdOutMin)
        public
        onlyNonContract
        nonReentrant
    {
        require(!zapMintPaused, "Collector: zap mint paused");
        require(_collatIn > 0, "Collector: _collatIn <= 0");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (depository.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Collector: Pool Ceiling"
        );

        uint256 _collatPrice = oracle.collatPrice();

        uint256 _collatFee = ((_collatIn * mintFee) / RATIO_PRECISION);
        uint256 _ausdFee = (_collatFee * MISSING_PRECISION * _collatPrice) /
            PRICE_PRECISION;
        uint256 _collatToMint = _collatIn - _collatFee;
        uint256 _collatToMintE18 = _collatToMint * MISSING_PRECISION;

        uint256 _atmPrice = oracle.atmPrice();
        uint256 _collatToBuy = 0;
        if (tcr < TCR_MAX) {
            _collatToBuy = _collatAmtToBuyShare(
                _collatToMint,
                _collatPrice,
                _atmPrice
            );
            _collatToMintE18 -= (_collatToBuy * MISSING_PRECISION);
        }

        collat.safeTransferFrom(msg.sender, address(this), _collatIn);
        uint256 _lpAmount = 0;
        if (_collatToBuy > 0) {
            collat.safeApprove(address(exchangeProvider), 0);
            collat.safeApprove(address(exchangeProvider), _collatToBuy);

            uint256 _minAtmAmt = (_collatToBuy *
                PRICE_PRECISION *
                (RATIO_PRECISION - zapSlippage)) /
                _atmPrice /
                RATIO_PRECISION /
                2;

            _lpAmount = exchangeProvider.zapInUsdc(_collatToBuy, _minAtmAmt, 0);
            _collatToMintE18 = (_collatToMintE18 * RATIO_PRECISION) / tcr;
            emit ZapSwapped(_collatToBuy, _lpAmount);
        }

        uint256 _ausdOut = (_collatToMintE18 * _collatPrice) / PRICE_PRECISION;
        require(_ausdOut >= _ausdOutMin, "Collect: aUSD slippage");

        if (_lpAmount > 0) {
            // transfer all lp token to Shredder
            IERC20 lpToken = IERC20(address(atmPair));
            lpToken.safeTransfer(shredder, lpToken.balanceOf(address(this)));
        }
        collat.safeTransfer(address(depository), collat.balanceOf(address(this)));
        ausd.mintByCollector(msg.sender, _ausdOut);
        ausd.mintByCollector(address(incomeManager), _ausdFee);
        _collatInfo();

        emit LogMint(_collatIn, 0, _ausdOut, _ausdFee);
    }

    function redeem(
        uint256 _ausdIn,
        uint256 _atmOutMin,
        uint256 _collatOutMin
    ) external onlyNonContract nonReentrant {
        require(!redeemPaused, "Collector: redeem paused");
        require(_ausdIn > 0, "Collector: ausd <= 0");

        uint256 _ausdFee = (_ausdIn * redeemFee) / RATIO_PRECISION;
        uint256 _ausdToRedeem = _ausdIn - _ausdFee;
        uint256 _atmOut = 0;
        uint256 _collatOut = (_ausdToRedeem * PRICE_PRECISION) /
            oracle.collatPrice() /
            MISSING_PRECISION;

        if (ecr < ECR_MAX) {
            uint256 _atmOutValue = _ausdToRedeem -
                ((_ausdToRedeem * ecr) / RATIO_PRECISION);
            _atmOut = (_atmOutValue * PRICE_PRECISION) / oracle.atmPrice();
            _collatOut = (_collatOut * ecr) / RATIO_PRECISION;
        }

        require(
            _collatOut <= totalCollatAmt(),
            "Collector: insufficient bank balance"
        );
        require(_collatOut >= _collatOutMin, "Collector: collat slippage");
        require(_atmOut >= _atmOutMin, "Collector: atm slippage");

        if (_collatOut > 0) {
            redeemCollatBal[msg.sender] += _collatOut;
            unclaimedCollat += _collatOut;
        }

        if (_atmOut > 0) {
            redeemAtmBal[msg.sender] += _atmOut;
            unclaimedAtm += _atmOut;
            atm.mintByCollector(address(depository), _atmOut);
        }

        lastRedeemed[msg.sender] = block.number;

        ausd.burn(msg.sender, _ausdToRedeem);
        ausd.safeTransferFrom(
            msg.sender,
            address(exchangeProvider),
            _ausdFee
        );
        _collatInfo();

        emit LogRedeem(_ausdIn, _collatOut, _atmOut, _ausdFee);
    }

    function collect() external onlyNonContract nonReentrant {
        require(
            lastRedeemed[msg.sender] + 1 <= block.number,
            "Collector: collect too soon"
        );

        uint256 _collatOut = redeemCollatBal[msg.sender];
        uint256 _atmOut = redeemAtmBal[msg.sender];

        if (_collatOut > 0) {
            redeemCollatBal[msg.sender] = 0;
            unclaimedCollat -= _collatOut;
            depository.transferCollatTo(msg.sender, _collatOut);
        }

        if (_atmOut > 0) {
            redeemAtmBal[msg.sender] = 0;
            unclaimedAtm -= _atmOut;
            depository.transferAtmTo(msg.sender, _atmOut);
        }

        _collatInfo();
    }

    function arbMint(uint256 _collatIn) external override nonReentrant onlyArb {
        require(!zapMintPaused, "Collector: zap mint paused");
        require(_collatIn > 0, "Collector: _collatIn <= 0");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (depository.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Collector: Pool Ceiling"
        );

        uint256 _collatPrice = oracle.collatPrice();
        uint256 _collatToMintE18 = _collatIn * MISSING_PRECISION;

        uint256 _atmPrice = oracle.atmPrice();
        uint256 _collatToBuy = 0;
        if (tcr < TCR_MAX) {
            _collatToBuy = _collatAmtToBuyShare(
                _collatIn,
                _collatPrice,
                _atmPrice
            );
            _collatToMintE18 -= (_collatToBuy * MISSING_PRECISION);
        }

        collat.safeTransferFrom(msg.sender, address(this), _collatIn);
        uint256 _lpAmount = 0;
        if (_collatToBuy > 0) {
            collat.safeApprove(address(exchangeProvider), 0);
            collat.safeApprove(address(exchangeProvider), _collatToBuy);

            uint256 _minAtmAmt = (_collatToBuy *
                PRICE_PRECISION *
                (RATIO_PRECISION - zapSlippage)) /
                _atmPrice /
                RATIO_PRECISION /
                2;

            _lpAmount = exchangeProvider.zapInUsdc(_collatToBuy, _minAtmAmt, 0);

            _collatToMintE18 = (_collatToMintE18 * RATIO_PRECISION) / tcr;
            emit ZapSwapped(_collatToBuy, _lpAmount);
        }

        uint256 _ausdOut = (_collatToMintE18 * _collatPrice) / PRICE_PRECISION;

        if (_lpAmount > 0) {
            // transfer all lp token to Shredder
            IERC20 lpToken = IERC20(address(atmPair));
            lpToken.safeTransfer(shredder, lpToken.balanceOf(address(this)));
        }
        collat.safeTransfer(address(depository), collat.balanceOf(address(this)));
        ausd.mintByCollector(msg.sender, _ausdOut);
        _collatInfo();

        emit ArbMint(_collatIn, _ausdOut);
    }

    function arbRedeem(uint256 _ausdIn)
        external
        override
        nonReentrant
        onlyArb
    {
        require(!redeemPaused, "Collector: redeem paused");
        require(_ausdIn > 0, "Collector: ausd <= 0");

        uint256 _atmOut = 0;
        uint256 _collatOut = (_ausdIn * PRICE_PRECISION) /
            oracle.collatPrice() /
            MISSING_PRECISION;

        if (ecr < ECR_MAX) {
            uint256 _atmOutValue = _ausdIn -
                ((_ausdIn * ecr) / RATIO_PRECISION);
            _atmOut = (_atmOutValue * PRICE_PRECISION) / oracle.atmPrice();
            _collatOut = (_collatOut * ecr) / RATIO_PRECISION;
        }

        require(
            _collatOut <= totalCollatAmt(),
            "Collector: insufficient bank balance"
        );

        if (_collatOut > 0) {
            depository.transferCollatTo(msg.sender, _collatOut);
        }

        if (_atmOut > 0) {
            atm.mintByCollector(msg.sender, _atmOut);
        }

        ausd.burn(msg.sender, _ausdIn);
        _collatInfo();

        emit ArbRedeem(_ausdIn, _collatOut, _atmOut);
    }

    // When the protocol is recollateralizing, we need to give a discount of ATM to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get ATM for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of ATM + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra ATM value from the bonus rate as an arb opportunity
    function recollateralize(uint256 _collatIn, uint256 _atmOutMin)
        external
        nonReentrant
        returns (uint256)
    {
        require(recollatPaused == false, "Collector: Recollat paused");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(
            (depository.globalCollateralBalance() + _collatIn) <= poolCeiling,
            "Collector: Pool Ceiling"
        );

        uint256 _collatInE18 = _collatIn * MISSING_PRECISION;
        uint256 _atmPrice = oracle.atmPrice();
        uint256 _collatPrice = oracle.collatPrice();

        // Get the amount of ATM actually available (accounts for throttling)
        uint256 _atmAvailable = recollatAvailable();

        // Calculated the attempted amount of ATM

        uint256 _atmOut = (_collatInE18 *
            _collatPrice *
            (RATIO_PRECISION + bonusRate)) /
            RATIO_PRECISION /
            _atmPrice;

        // Make sure there is ATM available
        require(_atmOut <= _atmAvailable, "Collector: Insuf ATM Avail For RCT");

        // Check slippage
        require(_atmOut >= _atmOutMin, "Collector: ATM slippage");

        // Take in the collateral and pay out the ATM
        collat.safeTransferFrom(msg.sender, address(depository), _collatIn);
        atm.mintByCollector(msg.sender, _atmOut);

        // Increment the outbound ATM, in E18
        // Used for recollat throttling
        rctHourlyCum[_curEpochHr()] += _atmOut;
        _collatInfo();
        
        emit Recollateralized(_collatIn, _atmOut);
        return _atmOut;
    }

    function recollatTheoAvailableE18() public view returns (uint256) {
        uint256 _ausdTotalSupply = ausd.totalSupply();
        uint256 _desiredCollatE24 = tcr * _ausdTotalSupply;  // tcr 1 * 100
        uint256 _effectiveCollatE24 = calcEcr() * _ausdTotalSupply; //

        // Return 0 if already overcollateralized
        // Otherwise, return the deficiency
        if (_effectiveCollatE24 >= _desiredCollatE24) return 0;
        else {
            return (_desiredCollatE24 - _effectiveCollatE24) / RATIO_PRECISION;
        }
    }

    function recollatAvailable() public view returns (uint256) {
        uint256 _atmPrice = oracle.atmPrice();

        // Get the amount of collateral theoretically available
        uint256 _recollatTheoAvailableE18 = recollatTheoAvailableE18();

        // Get the amount of ATM theoretically outputtable
        uint256 _atmTheoOut = (_recollatTheoAvailableE18 * PRICE_PRECISION) /
            _atmPrice;

        // See how much ATM has been issued this hour
        uint256 _currentHourlyRct = rctHourlyCum[_curEpochHr()];

        // Account for the throttling
        return _comboCalcBbkRct(_currentHourlyRct, rctMaxPerHour, _atmTheoOut);
    }

    // Internal functions

    // Returns the current epoch hour
    function _curEpochHr() internal view returns (uint256) {
        return (block.timestamp / 3600); // Truncation desired
    }

    function _comboCalcBbkRct(
        uint256 _cur,
        uint256 _max,
        uint256 _theo
    ) internal pure returns (uint256) {
        if (_max == 0) {
            // If the hourly limit is 0, it means there is no limit
            return _theo;
        } else if (_cur >= _max) {
            // If the hourly limit has already been reached, return 0;
            return 0;
        } else {
            // Get the available amount
            uint256 _available = _max - _cur;

            if (_theo >= _available) {
                // If the the theoretical is more than the available, return the available
                return _available;
            } else {
                // Otherwise, return the theoretical amount
                return _theo;
            }
        }
    }

    function _collatAmtToBuyShare(
        uint256 _collatAmt,
        uint256 _collatPrice,
        uint256 _atmPrice
    ) internal view returns (uint256) {
        uint256 _r0 = 0;
        uint256 _r1 = 0;

        if (address(atm) <= address(collat)) {
            (_r1, _r0, ) = atmPair.getReserves(); // r1 = USDC, r0 = ATM
        } else {
            (_r0, _r1, ) = atmPair.getReserves(); // r0 = USDC, r1 = ATM
        }

        uint256 _rSwapFee = RATIO_PRECISION - swapFee;

        uint256 _k = ((RATIO_PRECISION * RATIO_PRECISION) / tcr) -
            RATIO_PRECISION;
        uint256 _b = _r0 +
            ((_rSwapFee *
                _r1 *
                _atmPrice *
                RATIO_PRECISION *
                PRICE_PRECISION) /
                ATM_PRECISION /
                PRICE_PRECISION /
                _k /
                _collatPrice) -
            ((_collatAmt * _rSwapFee) / PRICE_PRECISION);

        uint256 _tmp = ((_b * _b) / PRICE_PRECISION) +
            ((4 * _rSwapFee * _collatAmt * _r0) /
                PRICE_PRECISION /
                PRICE_PRECISION);

        return
            ((Babylonian.sqrt(_tmp * PRICE_PRECISION) - _b) * RATIO_PRECISION) /
            (2 * _rSwapFee);
    }

    function mintAusdByProfit(uint256 _amount) external onlyOwnerOrOperator {
        require(_amount > 0, "Depository: Zero amount");
        require(ecr > tcr, "Depository: tcr >= ecr");

        uint256 _available = ((ausd.totalSupply() * (ecr - tcr))) / tcr;

        _available =
            _available -
            ((_available * depository.excessCollateralSafetyMargin()) /
                RATIO_PRECISION);

        uint256 _ammtToMint = Math.min(_available, _amount);

        ausd.mintByCollector(address(incomeManager), _ammtToMint);
    }

    function info()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return (tcr, ecr, mintFee, redeemFee);
    }

    function _collatInfo() internal {
        uint256 _investAmt = depository.getInvestingAmt();
        uint256 _idleAmt = collat.balanceOf(address(depository));
        emit CollatStats(_investAmt, _idleAmt);
    }
}
