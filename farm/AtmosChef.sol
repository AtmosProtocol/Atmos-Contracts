// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../common/AtmosProtocol.sol";
import "../common/RunExchange.sol";
import "../interfaces/IAtmosERC20.sol";
import "../interfaces/IAtmosChef.sol";

contract AtmosChef is IAtmosChef, AtmosProtocol, RunExchange {
    using SafeERC20 for IERC20;
    using SafeERC20 for IAtmosERC20;

    struct UserInfo {
        uint256 pid;
        uint256 amount;
        int256 rewardDebt;
        uint64 depositTime;
        uint64 vestingStarted;
    }
    struct PoolInfo {
        uint64 allocPoint;
        uint64 lastRewardTime;
        uint256 accAtmPerShare;
        uint64 lockDuration;
        uint256 vestingDuration;
        uint256 vestingPenalty;
    }

    IAtmosERC20 public atm;
    IUniswapV2Pair public atmPair;

    /// @notice Info of each Farm pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each Farm pool.
    IERC20[] public lpToken;

    /// @notice Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    mapping(address => bool) public addedTokens;

    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    uint256 public atmPerSecond;

    address public incomeManager;
    address public depository;
    address public shredder;

    uint64 public startTime;

    event Deposit(
        address indexed user,
        address indexed to,
        uint256 indexed pid,
        uint256 amount
    );
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        address indexed to
    );
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event HarvestWithPenalty(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 penalty
    );

    event LogPoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        uint64 lockDuration,
        uint256 vestingDuration,
        uint256 vestingPenalty
    );
    event LogSetPool(
        uint256 indexed pid,
        uint256 allocPoint,
        uint64 lockDuration,
        uint256 vestingDuration,
        uint256 vestingPenalty
    );
    event LogUpdatePool(
        uint256 indexed pid,
        uint64 lastRewardTime,
        uint256 accAdded,
        uint256 accAtmPerShare
    );
    event LogAtmPerSecond(uint256 atmPerSecond);
    event IncomeManagerUpdated(address incomeManager);
    event LogSetAtm(address _atm, address atmPair);
    event DistributePenalty(uint256 depositoryAmt, uint256 incomeManagerAmt);
    event LogSetDepostory(address depository);
    event LogSetShredder(address shredder);

    /// @param _atm The ATM token contract address.
    constructor(
        address _atm,
        address _atmPair,
        address _exchangeProvider,
        address _incomeManager,
        address _depository,
        address _shredder,
        uint64 _startTime
    ) {
        setAtm(_atm, _atmPair);

        setExchangeProvider(_exchangeProvider);
        setIncomeManager(_incomeManager);
        setDepository(_depository);
        setShredder(_shredder);

        startTime = _startTime;
    }

    /// @notice Returns the number of Farm pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint64 _lockDuration,
        uint256 _vestingDuration,
        uint256 _penalty
    ) public onlyOwner {
        require(addedTokens[address(_lpToken)] == false, "Token already added");
        massUpdatePools();

        totalAllocPoint += _allocPoint;
        lpToken.push(_lpToken);

        uint64 _startTime = _currentBlockTs() > startTime
            ? _currentBlockTs()
            : startTime;

        poolInfo.push(
            PoolInfo({
                allocPoint: SafeCast.toUint64(_allocPoint),
                lastRewardTime: _startTime,
                accAtmPerShare: 0,
                lockDuration: _lockDuration,
                vestingDuration: _vestingDuration,
                vestingPenalty: _penalty
            })
        );
        addedTokens[address(_lpToken)] = true;
        emit LogPoolAddition(
            lpToken.length - 1,
            _allocPoint,
            _lpToken,
            _lockDuration,
            _vestingDuration,
            _penalty
        );
    }

    /// @notice Update the given pool's ATM allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint64 _lockDuration,
        uint256 _vestingDuration,
        uint256 _penalty
    ) public onlyOwner {
        massUpdatePools();

        totalAllocPoint =
            totalAllocPoint -
            poolInfo[_pid].allocPoint +
            _allocPoint;
        PoolInfo storage pool = poolInfo[_pid];
        pool.allocPoint = SafeCast.toUint64(_allocPoint);
        pool.lockDuration = SafeCast.toUint64(_lockDuration);
        pool.vestingDuration = _vestingDuration;
        pool.vestingPenalty = _penalty;

        emit LogSetPool(
            _pid,
            _allocPoint,
            _lockDuration,
            _vestingDuration,
            _penalty
        );
    }

    /// @notice Sets the ATM per second to be distributed. Can only be called by the owner.
    function setAtmPerSecond(uint256 _atmPerSecond) public onlyOwner {
        massUpdatePools();

        atmPerSecond = _atmPerSecond;
        emit LogAtmPerSecond(atmPerSecond);
    }

    /// @dev Calculated amount of accAtmPerShare to add to the pool.
    function _calcAccAtmToAdd(uint256 _pid) internal view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        uint256 _lpSupply = lpToken[_pid].balanceOf(address(this));
        uint256 _lpDecimals = ERC20(address(lpToken[_pid])).decimals();
        uint64 _currentTs = _currentBlockTs();
        if (_currentTs <= pool.lastRewardTime || _lpSupply <= 0) {
            return 0;
        }
        uint256 _time = _currentTs - pool.lastRewardTime;
        uint256 _atmReward = (_time * atmPerSecond * pool.allocPoint) /
            totalAllocPoint;
        return (_atmReward * (10**_lpDecimals)) / _lpSupply;
    }

    /// @notice View function to see pending ATM on frontend.
    function pendingAtm(uint256 _pid, address _user)
        external
        view
        returns (uint256 pending)
    {
        PoolInfo memory _pool = poolInfo[_pid];
        UserInfo memory _userInfo = userInfo[_pid][_user];

        uint256 _accAtmPerShare = _pool.accAtmPerShare + _calcAccAtmToAdd(_pid);
        pending = SafeCast.toUint256(
            int256((_userInfo.amount * _accAtmPerShare) / ATM_PRECISION) -
                _userInfo.rewardDebt
        );
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    /// @notice Update reward variables of the given pool.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 _pid)
        public
        nonReentrant
        returns (PoolInfo memory pool)
    {
        pool = poolInfo[_pid];
        uint256 _accToAdd = _calcAccAtmToAdd(_pid);
        if (_accToAdd > 0) {
            pool.accAtmPerShare += _accToAdd;
        }
        uint64 _currentTs = _currentBlockTs();
        if (_currentTs > pool.lastRewardTime) {
            pool.lastRewardTime = _currentTs;
            poolInfo[_pid] = pool;
            emit LogUpdatePool(
                _pid,
                pool.lastRewardTime,
                _accToAdd,
                pool.accAtmPerShare
            );
        }
    }

    /// @notice Deposit LP tokens to Farm for ATM allocation.
    function deposit(
        uint256 _pid,
        uint256 _amount,
        address _to
    ) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][_to];

        lpToken[_pid].safeTransferFrom(msg.sender, address(this), _amount);

        // Effects
        _user.pid = _pid;
        _user.amount += _amount;
        _user.rewardDebt += int256(
            (_amount * _pool.accAtmPerShare) / ATM_PRECISION
        );
        _user.depositTime = _currentBlockTs();
        _user.vestingStarted = _currentBlockTs();

        emit Deposit(msg.sender, _to, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from Farm.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];

        require(
            _user.depositTime + _pool.lockDuration <= _currentBlockTs(),
            "AtmosChef: Withdraw lock"
        );

        // Effects
        _user.rewardDebt -= int256(
            (_amount * _pool.accAtmPerShare) / ATM_PRECISION
        );
        _user.amount -= _amount;

        lpToken[_pid].safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Harvest proceeds for transaction sender.
    function harvest(uint256 _pid) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];
        int256 _accumulatedAtm = int256(
            (_user.amount * _pool.accAtmPerShare) / ATM_PRECISION
        );
        uint256 _pendingAtm = SafeCast.toUint256(
            _accumulatedAtm - _user.rewardDebt
        );

        // Effects
        _user.rewardDebt = _accumulatedAtm;

        // Interactions
        if (_pendingAtm > 0) {
            require(
                canClaimVesting(_user.vestingStarted, _pid),
                "AtmosChef: Not yet to claim"
            );
            atm.mintByFarm(msg.sender, _pendingAtm);
        }

        emit Harvest(msg.sender, _pid, _pendingAtm);
    }

    /// @notice Harvest proceeds for transaction sender.
    function harvestWithPenalty(uint256 _pid) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];
        int256 _accumulatedAtm = int256(
            (_user.amount * _pool.accAtmPerShare) / ATM_PRECISION
        );
        uint256 _pendingAtm = SafeCast.toUint256(
            _accumulatedAtm - _user.rewardDebt
        );

        // Effects
        _user.rewardDebt = _accumulatedAtm;

        // Interactions
        if (_pendingAtm > 0) {
            require(
                !canClaimVesting(_user.vestingStarted, _pid),
                "AtmosChef: Can normally harvest"
            );
            uint256 poolPenalty = poolInfo[_pid].vestingPenalty;
            uint256 _penalty = (_pendingAtm * poolPenalty) / RATIO_PRECISION;
            uint256 _amount = _pendingAtm - _penalty;

            atm.mintByFarm(msg.sender, _amount);
            _distributePenalty(_penalty);

            emit HarvestWithPenalty(msg.sender, _pid, _pendingAtm, _penalty);
        }
    }

    /// @dev Distribute penalty (ATM) to Depository (2/3 -> ATM-USDC LP) and IncomeManager (1/3 -> ATM).
    function _distributePenalty(uint256 _amount) internal {
        require(_amount > 0, "AtmosChef: Zero amount");
        require(shredder != address(0), "AtmosChef: Shredder not set");
        require(incomeManager != address(0), "Farm: ProfitController not set");

        uint256 _shredderAmt = (_amount * 2) / 3;

        atm.mintByFarm(address(this), _amount);
        atm.safeApprove(address(exchangeProvider), 0);
        atm.safeApprove(address(exchangeProvider), _shredderAmt);
        uint256 lpAmt = exchangeProvider.zapInAtm(_shredderAmt, 0, 0);

        require(
            atmPair.transfer(shredder, lpAmt),
            "AtmosChef: Failed to transfer"
        );

        uint256 _incomeManagerAmt = _amount - _shredderAmt;
        if (_incomeManagerAmt > 0) {
            atm.safeTransfer(incomeManager, _incomeManagerAmt);
        }

        emit DistributePenalty(_shredderAmt, _incomeManagerAmt);
    }

    /// @notice Withdraw LP tokens from Farm and harvest proceeds for transaction sender.
    function withdrawAndHarvest(uint256 _pid, uint256 _amount) public override {
        PoolInfo memory _pool = updatePool(_pid);
        UserInfo storage _user = userInfo[_pid][msg.sender];

        require(
            _user.depositTime + _pool.lockDuration <= _currentBlockTs(),
            "AtmosChef: Withdraw lock"
        );

        int256 _accumulatedAtm = int256(
            (_user.amount * _pool.accAtmPerShare) / ATM_PRECISION
        );
        uint256 _pendingAtm = SafeCast.toUint256(
            _accumulatedAtm - _user.rewardDebt
        );

        // Effects
        _user.rewardDebt =
            _accumulatedAtm -
            int256((_amount * _pool.accAtmPerShare) / ATM_PRECISION);
        _user.amount -= _amount;

        // Interactions
        if (_pendingAtm > 0) {
            require(
                canClaimVesting(_user.vestingStarted, _pid),
                "AtmosChef: Not yet to harvest"
            );
            atm.mintByFarm(msg.sender, _pendingAtm);
        }

        lpToken[_pid].safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _pid, _amount);
        emit Harvest(msg.sender, _pid, _pendingAtm);
    }

    function canClaimVesting(uint64 _startTime, uint256 _pid)
        public
        view
        returns (bool)
    {
        PoolInfo memory pool = poolInfo[_pid];
        return _currentBlockTs() >= (_startTime + pool.vestingDuration);
    }

    function getUserInfo(address _user)
        external
        view
        returns (UserInfo[] memory)
    {
        UserInfo[] memory _returnInfos = new UserInfo[](poolInfo.length);

        for (uint256 i = 0; i < poolInfo.length; i++) {
            UserInfo memory _userInfo = userInfo[i][_user];
            _returnInfos[i] = _userInfo;
        }

        return _returnInfos;
    }

    function getLpToken(uint256 _pid) external view override returns (address) {
        return address(lpToken[_pid]);
    }

    function setIncomeManager(address _incomeManager) public onlyOwner {
        require(_incomeManager != address(0), "AtmosChef: Address zero");
        incomeManager = _incomeManager;
        emit IncomeManagerUpdated(_incomeManager);
    }

    function setAtm(address _atm, address _atmPair) public onlyOwner {
        require(_atm != address(0), "AtmosChef: Address zero");
        require(_atmPair != address(0), "AtmosChef: Address zero");
        atm = IAtmosERC20(_atm);
        atmPair = IUniswapV2Pair(_atmPair);
        emit LogSetAtm(_atm, _atmPair);
    }

    function setDepository(address _depository) public onlyOwner {
        require(_depository != address(0), "AtmosChef: Address zero");
        depository = _depository;
        emit LogSetDepostory(depository);
    }

    function setShredder(address _shredder) public onlyOwner {
        require(_shredder != address(0), "AtmosChef: Address zero");
        shredder = _shredder;
        emit LogSetShredder(shredder);
    }
}
