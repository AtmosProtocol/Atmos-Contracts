pragma solidity ^0.8.0;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IAtmosERC20.sol";

contract TokenSale is Ownable {

    using SafeERC20 for IAtmosERC20;
    using SafeERC20 for IERC20;

    IAtmosERC20 public atm;
    IERC20 public immutable usdc;

    bool public saleStarted = false;
    bool public saleFinished = false;
    uint256 public soldAmount;

    struct UserClaimInfo {
        uint256 totalAtm;
        uint256 atmAmt;
        uint256 deposited;
        uint256 lastClaimed;
        bool firstTimeClaimed;
        bool userExist;
    }

    uint256 public constant ONE_WEEK = 7 days; // 1 week
    uint256 public constant MAX_USD_DEPOSIT_AMOUNT = 5000000000; // 5000 USDC
    uint256 public constant MISSING_DECIMALS = 1e12;
    uint256 public constant ATM_PRICE = 175;
    uint256 public constant ATM_PRICE_DECIMALS = 1000;
    uint256 public constant WEEKLY_CLAIM = 35; // 3.5%
    uint256 public constant INITIAL_CLAIM = 300; // 30%
    uint256 public constant CLAIM_DECIMALS = 1000; // percent decimals
    uint256 public immutable TOTAL_SALE_ALLOCATED; // sale allocation
    

    mapping (address => UserClaimInfo) public users;
   
    constructor(address _usdc, uint256 _allocation) {
        usdc = IERC20(_usdc);
        TOTAL_SALE_ALLOCATED = _allocation;
    }

    function initAtm(address _atm) external onlyOwner {
        require(address(atm) == address(0), "already done");
        atm = IAtmosERC20(_atm);
    }

    function start() external onlyOwner {
        require(!saleStarted, "sale already started");
        saleStarted = true;
        soldAmount = 0;
    }

    function stop() external onlyOwner {
        require(saleStarted, "sale not started yet");
        saleFinished = true;
        uint256 usdcBalance = usdc.balanceOf(address(this));

        usdc.safeTransfer(owner(), usdcBalance);
    }

    function deposit(uint256 _usdcAmt) external {

        require(saleStarted, "sale not started yet");
        require(!saleFinished, "sale is finished");

        uint256 atmBoughtAmt = (_usdcAmt * MISSING_DECIMALS) * ATM_PRICE_DECIMALS / ATM_PRICE;
        require(soldAmount + atmBoughtAmt <= TOTAL_SALE_ALLOCATED, "sale limit reached");
        soldAmount += atmBoughtAmt;

        if (!users[msg.sender].userExist) {
            require(_usdcAmt <= MAX_USD_DEPOSIT_AMOUNT, "Max deposit amount is 5000 USDC");
            users[msg.sender] = UserClaimInfo(atmBoughtAmt, atmBoughtAmt, _usdcAmt, 0, false, true);
            usdc.transferFrom(msg.sender, address(this), _usdcAmt);
        } else {
            require(_usdcAmt + users[msg.sender].deposited <= MAX_USD_DEPOSIT_AMOUNT, "Sum deposit amount shouldn't be greater than 5000 USDC");
            usdc.transferFrom(msg.sender, address(this), _usdcAmt);

            UserClaimInfo storage user = users[msg.sender];
            user.deposited += _usdcAmt;
            user.atmAmt += atmBoughtAmt;
            user.totalAtm += atmBoughtAmt;
         }
    }

    function claim() external {
        require(address(atm) != address(0), "please init atm");
        require(saleFinished, "sale isn't finished yet");
        require(users[msg.sender].userExist, "no such user");
        require(users[msg.sender].atmAmt > 0, "zero balance");

        uint256 claimTime = block.timestamp;
        

        if (!users[msg.sender].firstTimeClaimed) {
            uint256 amtToSend = users[msg.sender].totalAtm * INITIAL_CLAIM / CLAIM_DECIMALS;
            atm.safeTransfer(msg.sender, amtToSend);

            users[msg.sender].lastClaimed = claimTime;
            users[msg.sender].atmAmt -= amtToSend;
            users[msg.sender].firstTimeClaimed = true;
        } else {
            require(users[msg.sender].lastClaimed + ONE_WEEK <= claimTime, "not available yet");
            
            uint256 amtToSend = users[msg.sender].totalAtm * WEEKLY_CLAIM / CLAIM_DECIMALS;
            atm.safeTransfer(msg.sender, amtToSend);

            users[msg.sender].lastClaimed = claimTime;
            users[msg.sender].atmAmt -= amtToSend;
        }

    }

    function rescueAtm() external onlyOwner {
        require(saleFinished, "sale isn't finished");
        uint256 atmBal = atm.balanceOf(address(this));
        atm.safeTransfer(owner(), atmBal);
    }

    function rescueUSDC() external onlyOwner {
        require(saleFinished, "sale isn't finished");
        uint256 usdcBal = usdc.balanceOf(address(this));
        usdc.safeTransfer(owner(), usdcBal);
    }
}
