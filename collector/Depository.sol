// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../common/AtmosProtocol.sol";
import "../common/OnlyCollector.sol";
import "../interfaces/IDepository.sol";
import "../interfaces/ICollector.sol";
import "../interfaces/IAtmosERC20.sol";
import "../compound/IAuToken.sol";

contract Depository is IDepository, AtmosProtocol, OnlyCollector {
    using SafeERC20 for IERC20;
    using SafeERC20 for IAtmosERC20;

    IERC20 public collat;
    IAtmosERC20 public atm;

    uint256 public override investingAmt;
    address public incomeManager;

    uint256 public idleCollateralUtilizationRatio; // ratio where idle collateral can be used for investment
    uint256 public constant IDLE_COLLATERAL_UTILIZATION_RATIO_MAX = 850000; // no more than 85%

    uint256 public reservedCollateralThreshold; // ratio of the threshold where collateral are reserved for redemption
    uint256 public constant RESERVE_COLLATERAL_THRESHOLD_MIN = 150000; // no less than 15%

    uint256 public override excessCollateralSafetyMargin;
    uint256 public constant EXCESS_COLLATERAL_SAFETY_MARGIN_MIN = 100000; // 10%

    IAuToken public auToken;
    IERC20 public rewardToken;

    bool private isInvestEntered = false;

    event IncomeManagerUpdated(address indexed profitController);
    event IncomeExtracted(uint256 amount);
    event InvestDeposited(uint256 amount);
    event InvestWithdrawn(uint256 amount);
    event IncentivesClaimed(uint256 amount);
    event IdleCollateralUtilizationRatioUpdated(uint256 ratio);
    event ReservedCollateralThresholdUpdated(uint256 ratio);
    event ExcessCollateralSafetyMarginUpdated(uint256 ratio);
    event AuTokenUpdated(address auToken);

    constructor(
        address _collector,
        address _collat,
        address _atm,
        address _incomeManager,
        address _auToken
    ) OnlyCollector(_collector) {
        collat = IERC20(_collat);
        atm = IAtmosERC20(_atm);
        setIncomeManager(_incomeManager);
        setAuToken(_auToken);

        setExcessCollateralSafetyMargin(EXCESS_COLLATERAL_SAFETY_MARGIN_MIN);
        setIdleCollateralUtilizationRatio(
            IDLE_COLLATERAL_UTILIZATION_RATIO_MAX
        );
        setReservedCollateralThreshold(RESERVE_COLLATERAL_THRESHOLD_MIN);
    }

    function transferCollatTo(address _to, uint256 _amt)
        external
        override
        onlyCollector
    {
        require(_to != address(0), "Depository: invalid address");

        if (_amt > collat.balanceOf(address(this))) {
            // If low in balance, rebalance investment
            if (isInvestEntered) {
                exitInvest();
                collat.safeTransfer(_to, _amt);
                enterInvest();
            } else {
                revert("Depository: Insufficient balance");
            }
        } else {
            collat.safeTransfer(_to, _amt);
        }
    }

    function transferAtmTo(address _to, uint256 _amt)
        external
        override
        onlyCollector
    {
        require(_to != address(0), "Depository: invalid address");
        atm.safeTransfer(_to, _amt);
    }

    function globalCollateralBalance() public view override returns (uint256) {
        uint256 _collateralReserveBalance = collat.balanceOf(address(this));

        return
            _collateralReserveBalance +
            investingAmt -
            ICollector(collector).unclaimedCollat();
    }

    function enterInvest() public nonReentrant {
        require(
            msg.sender == address(collector) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Depository: enterInvest no auth"
        );
        require(isInvestEntered == false, "Investment already entered");

        uint256 _collateralBalance = IERC20(collat).balanceOf(address(this));

        uint256 _investmentAmount = (idleCollateralUtilizationRatio *
            _collateralBalance) / RATIO_PRECISION;

        if (_investmentAmount > 0) {
            _depositInvest(_investmentAmount);
            isInvestEntered = true;
        }
    }

    function exitInvest() public returns (uint256 profit) {
        require(
            msg.sender == address(collector) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Depository: enterInvest no auth"
        );
        profit = _withdrawInvest();
        isInvestEntered = false;
    }

    function rebalanceInvest() public {
        require(
            msg.sender == address(collector) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Safe: enterInvest no auth"
        );
        if (isInvestEntered) {
            exitInvest();
        }
        enterInvest();
    }

    function rebalanceIfUnderThreshold() external {
        require(
            msg.sender == address(collector) ||
                msg.sender == owner() ||
                msg.sender == operator,
            "Depository: enterInvest no auth"
        );
        if (!isAboveThreshold()) {
            rebalanceInvest();
        }
    }

    function _depositInvest(uint256 _amount) internal {
        require(_amount > 0, "Zero amount");
        investingAmt = _amount;
        collat.safeApprove(address(auToken), 0);
        collat.safeApprove(address(auToken), investingAmt);
        auToken.mint(investingAmt);
        emit InvestDeposited(_amount);
    }

    function _withdrawInvest() internal nonReentrant returns (uint256) {
        uint256 oldBalance = collat.balanceOf(address(this));
        auToken.redeem(balanceOfAuToken());
        uint256 newBalance = collat.balanceOf(address(this));
        uint256 withdrawnBalance = newBalance - oldBalance;
        uint256 profit = 0;
        if (withdrawnBalance > investingAmt) {
            profit = withdrawnBalance - investingAmt;
        }
        investingAmt = 0;
        emit InvestWithdrawn(withdrawnBalance);
        return profit;
    }

    function extractProfit(uint256 _amount) external onlyOwnerOrOperator {
        require(_amount > 0, "Depository: Zero amount");
        require(
            incomeManager != address(0),
            "Depository: Invalid incomeManager"
        );
        uint256 _maxExcess = excessCollateralBalance();
        uint256 _maxAllowableAmount = _maxExcess -
            ((_maxExcess * excessCollateralSafetyMargin) / RATIO_PRECISION);

        uint256 _amtToTransfer = Math.min(_maxAllowableAmount, _amount);
        IERC20(collat).safeTransfer(incomeManager, _amtToTransfer);
        emit IncomeExtracted(_amtToTransfer);
    }

    function excessCollateralBalance() public view returns (uint256 _excess) {
        uint256 _tcr = ICollector(collector).tcr();
        uint256 _ecr = ICollector(collector).ecr();
        if (_ecr <= _tcr) {
            _excess = 0;
        } else {
            _excess =
                ((_ecr - _tcr) * globalCollateralBalance()) /
                RATIO_PRECISION;
        }
    }

    function balanceOfAuToken() public view returns (uint256) {
        return auToken.balanceOf(address(this));
    }

    function setIncomeManager(address _incomeManager) public onlyOwner {
        require(_incomeManager != address(0), "Invalid IncomeManager");
        incomeManager = _incomeManager;
        emit IncomeManagerUpdated(_incomeManager);
    }

    function calcCollateralReserveRatio() public view returns (uint256) {
        uint256 _collateralReserveBalance = IERC20(collat).balanceOf(
            address(this)
        );
        uint256 _collateralBalanceWithoutInvest = _collateralReserveBalance -
            ICollector(collector).unclaimedCollat();
        uint256 _globalCollateralBalance = globalCollateralBalance();
        if (_globalCollateralBalance == 0) {
            return 0;
        }
        return
            (_collateralBalanceWithoutInvest * RATIO_PRECISION) /
            _globalCollateralBalance;
    }

    function isAboveThreshold() public view returns (bool) {
        uint256 _ratio = calcCollateralReserveRatio();
        uint256 _threshold = reservedCollateralThreshold;
        return _ratio >= _threshold;
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

    function setIdleCollateralUtilizationRatio(
        uint256 _idleCollateralUtilizationRatio
    ) public onlyOwnerOrOperator {
        require(
            _idleCollateralUtilizationRatio <=
                IDLE_COLLATERAL_UTILIZATION_RATIO_MAX,
            ">idle max"
        );
        idleCollateralUtilizationRatio = _idleCollateralUtilizationRatio;
        emit IdleCollateralUtilizationRatioUpdated(
            idleCollateralUtilizationRatio
        );
    }

    function setReservedCollateralThreshold(
        uint256 _reservedCollateralThreshold
    ) public onlyOwnerOrOperator {
        require(
            _reservedCollateralThreshold >= RESERVE_COLLATERAL_THRESHOLD_MIN,
            "<threshold min"
        );
        reservedCollateralThreshold = _reservedCollateralThreshold;
        emit ReservedCollateralThresholdUpdated(reservedCollateralThreshold);
    }

    function setExcessCollateralSafetyMargin(
        uint256 _excessCollateralSafetyMargin
    ) public onlyOwnerOrOperator {
        require(
            _excessCollateralSafetyMargin >=
                EXCESS_COLLATERAL_SAFETY_MARGIN_MIN,
            "<margin min"
        );
        excessCollateralSafetyMargin = _excessCollateralSafetyMargin;
        emit ExcessCollateralSafetyMarginUpdated(excessCollateralSafetyMargin);
    }

    function setAuToken(address _auToken) public onlyOwner {
        require(_auToken != address(0), "Invalid address");
        auToken = IAuToken(_auToken);
        emit AuTokenUpdated(_auToken);
    }

    function getInvestingAmt() external view override returns(uint256) {
        return investingAmt;
    }
}
