// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../common/AtmosProtocol.sol";
import "../interfaces/IAtmosStake.sol";

contract AtmosStakeV2 is AtmosProtocol, IAtmosStake {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /*      UINT256       */
    uint256 public totalAtmLocked;
    uint256 public totalShares;
    uint256 public constant MIN_LOCK_DURATION = 7 days; // 7 days
    uint256 public constant MAX_LOCK_DURATION = 365 days; // 365 days
    uint256 public constant EPOCH_PERIOD = 1 days;
    uint256 public constant PRECISION_FACTOR = 1e18; 

    /*      STRUCT       */
    struct UserInfo {
        uint256 depositedAmount;
        uint256 veAtmAmount;
        uint256 unlockTime;
        uint256 rewardDebt;
        uint256 lastDeposit;
    }

    struct PoolInfo {
        IERC20 stakeToken;
        uint256 accRewardPerShare; // Accumulated rewards per share, times PRECISION_FACTOR
    }

    /*      IERC20       */
    IERC20 public atm;

    /*      ADDRESS       */
    address public incomeManager;

    /*      BOOL       */
    bool public stakePaused = false;

    /*      Other       */
    PoolInfo public poolInfo;
    mapping(address => UserInfo) public userInfo;

    modifier onlyIncomeManager() {
        require(
            msg.sender == owner() || msg.sender == incomeManager,
            "Only profit controller"
        );
        _;
    }

    /*      Events      */
    event Deposit(address indexed user, uint256 amount, uint256 lockPeriod);
    event Withdraw(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event ProfitDistributed(uint256 amount);
    event IncomeManagerUpdated(address incomeManager);
    event StakePaused();
    event Tvl(uint256 totalAtm, uint256 totalShares);

    constructor(IERC20 _atm, address _incomeManager) {
        atm = _atm;
        setIncomeManager(_incomeManager);

        poolInfo = PoolInfo({stakeToken: _atm, accRewardPerShare: 0});
    }

    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 accRewardPerShare = poolInfo.accRewardPerShare;
        uint256 stakeTokenSupply = totalShares;

        if (stakeTokenSupply != 0) {
            return
                (user.veAtmAmount * accRewardPerShare) /
                PRECISION_FACTOR -
                user.rewardDebt;
        }

        return 0;
    }

    function stake(uint256 _amount, uint256 _lockPeriodDays) public {
        require(!stakePaused, "Stake is paused");
        require(
            _lockPeriodDays * EPOCH_PERIOD >= MIN_LOCK_DURATION,
            "Lock period to low"
        );
        require(
            _lockPeriodDays * EPOCH_PERIOD <= MAX_LOCK_DURATION,
            "Lock period to low"
        );
        UserInfo storage user = userInfo[msg.sender];

        if (_amount > 0) {
            uint256 _unlockTime = block.timestamp.add(
                _lockPeriodDays * EPOCH_PERIOD
            );
            require(
                _unlockTime >= user.unlockTime,
                "New lock period can't be lower then current"
            );

            // Additional shares for the lock period.
            uint256 _bonus = _amount.mul(_lockPeriodDays.mul(EPOCH_PERIOD)).div(
                MAX_LOCK_DURATION
            );
            uint256 _veAtmOut = _amount.add(_bonus);

            user.lastDeposit = block.timestamp;
            user.unlockTime = _unlockTime;
            user.veAtmAmount += _veAtmOut;
            user.depositedAmount += _amount;
            user.rewardDebt =
                (user.veAtmAmount * poolInfo.accRewardPerShare) /
                PRECISION_FACTOR;

            totalAtmLocked += _amount;
            totalShares += _veAtmOut;

            atm.safeTransferFrom(address(msg.sender), address(this), _amount);
        }

        emit Deposit(msg.sender, _amount, _lockPeriodDays);
        emit Tvl(totalAtmLocked, totalShares);
    }

    function unstake(uint256 _amount) public {
        require(!stakePaused, "Stake: Paused");

        UserInfo storage user = userInfo[msg.sender];
        require(user.unlockTime <= block.timestamp, "Stake: Not expired");
        require(user.depositedAmount >= _amount, "Stake: Amount is too big");

        uint256 pending = (user.veAtmAmount * poolInfo.accRewardPerShare) /
            PRECISION_FACTOR -
            user.rewardDebt;

        if (pending > 0) {
            atm.safeTransfer(address(msg.sender), pending);
        }

        if (_amount > 0) {
            uint256 bonusMultiplier = (PRECISION_FACTOR * user.veAtmAmount) /
                user.depositedAmount;
            user.depositedAmount -= _amount;
            user.veAtmAmount -= (_amount * bonusMultiplier) / PRECISION_FACTOR;

            totalAtmLocked -= _amount;
            totalShares -= (_amount * bonusMultiplier) / PRECISION_FACTOR;

            poolInfo.stakeToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt =
            (user.veAtmAmount * poolInfo.accRewardPerShare) /
            PRECISION_FACTOR;

        emit Withdraw(msg.sender, _amount);
        emit Tvl(totalAtmLocked, totalShares);
    }

    function harvest() public {
        require(!stakePaused, "Stake: Paused");

        UserInfo storage user = userInfo[msg.sender];

        uint256 pending = (user.veAtmAmount * poolInfo.accRewardPerShare) /
            PRECISION_FACTOR -
            user.rewardDebt;

        if (pending > 0) {
            atm.safeTransfer(address(msg.sender), pending);
        }

        user.rewardDebt =
            (user.veAtmAmount * poolInfo.accRewardPerShare) /
            PRECISION_FACTOR;
    }

    function emergencyWithdraw() public {
        require(stakePaused, "Only in emergency situations!");
        UserInfo storage user = userInfo[msg.sender];
        uint256 amountToTransfer = user.depositedAmount;
        uint256 userShares = user.veAtmAmount;

        totalAtmLocked -= amountToTransfer;
        totalShares -= userShares;

        user.depositedAmount = 0;
        user.veAtmAmount = 0;
        user.rewardDebt = 0;

        if (amountToTransfer > 0) {
            atm.safeTransfer(address(msg.sender), amountToTransfer);
        }

        emit EmergencyWithdraw(msg.sender, amountToTransfer);
        emit Tvl(totalAtmLocked, totalShares);
    }

    function setStakePaused() public onlyOwnerOrOperator {
        stakePaused = !stakePaused;
        emit StakePaused();
    }

    function distribute(uint256 _amount)
        external
        override
        onlyIncomeManager
    {
        require(_amount != 0, "Stake: Amount must be greater than 0");
        atm.safeTransferFrom(incomeManager, address(this), _amount);
        _distribute(_amount);

        emit ProfitDistributed(_amount);
    }

    function _distribute(uint256 _amount) internal {
        if (totalShares == 0) {
            return;
        }

        uint256 Reward = _amount;
        poolInfo.accRewardPerShare += (Reward * PRECISION_FACTOR) / totalShares;
    }

    function transferTo(
        address _receiver,
        address _token,
        uint256 _amount
    ) public onlyOwner {
        require(_amount > 0, "Zero amount");
        IERC20 token = IERC20(_token);
        if (_token == address(atm)) {
            require(
                token.balanceOf(address(this)) >= _amount + totalAtmLocked,
                "Not enough balance"
            );
        }

        token.safeTransfer(_receiver, _amount);
    }

    function setIncomeManager(address _incomeManager) public onlyOwner {
        require(_incomeManager != address(0), "Invalid address");
        incomeManager = _incomeManager;
        emit IncomeManagerUpdated(_incomeManager);
    }
}
