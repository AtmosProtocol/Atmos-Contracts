// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IExchangeProvider.sol";
import "../interfaces/IUniswapV2Router.sol";
import "./AtmosProtocol.sol";
import "../libraries/TransferHelper.sol";
import "../libraries/Babylonian.sol";
import "hardhat/console.sol";


interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
    function balanceOf(address account) external view returns (uint256);
}

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
    function div(uint a, uint b) internal pure returns (uint c) {
        require(b > 0, 'ds-math-division-by-zero');
        c = a / b;
    }
}

contract ExchangeProvider is IExchangeProvider, AtmosProtocol {
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    uint256 private constant TIMEOUT = 300;

    IUniswapV2Router public fbRouter;
    IUniswapV2Factory public fbFactory;
    IUniswapV2Pair public fbAtmPair;
    IUniswapV2Pair public fbAusdPair;

    address public WBNB;  // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!


    uint public maxResidual = 100; // 1%, set 10000 to disable

    IERC20 public atm;
    IERC20 public ausd;
    IERC20 public usdc;
    IERC20 public weth;

    address[] public fbAtmPairPath;
    address[] public fbAusdPairPath;
    address[] public fbWethPairPath;

    address[] public fbUsdcAtmPairPath;
    address[] public fbUsdcAusdPairPath;
    address[] public fbUsdcWethPairPath;

    uint8[] private fbDexIdsFB;
    uint8[] private fbDexIdsQuick;

    event LogSetContracts(
        address fbRouter,
        address fbFactory,
        address fbAtmPair,
        address fbAusdPair
    );
    event LogSetPairPaths(
        address[] fbAtmPairPath,
        address[] fbAusdPairPath,
        address[] fbWethPairPath
    );
    event LogSetDexIds(uint8[] fbDexIdsFB, uint8[] fbDexIdsQuick);

    constructor(
        address _router,
        address _factory,
        address _atmPair,
        address _ausdPair,
        address _atm,
        address _ausd,
        address _usdc, // 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
        address _weth // 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
    ) {
        require(
            _router != address(0) &&
            _factory != address(0) &&
            _atmPair != address(0) &&
            _ausdPair != address(0),
            "Exchange: Invalid Address"
        );

        setContracts( _router, _factory, _atmPair, _ausdPair);

        address[] memory _ATMPairPath = new address[](2);
        _ATMPairPath[0] = _atm;
        _ATMPairPath[1] = _usdc;
        address[] memory _AusdPairPath = new address[](2);
        _AusdPairPath[0] = _ausd;
        _AusdPairPath[1] = _usdc;
        address[] memory _WethPairPath = new address[](2);
        _WethPairPath[0] = _weth;
        _WethPairPath[1] = _usdc;
        setPairPaths(_ATMPairPath, _AusdPairPath, _WethPairPath);

        fbUsdcAtmPairPath = [_usdc, _atm];
        fbUsdcAusdPairPath = [_usdc, _ausd];
        fbUsdcWethPairPath = [_usdc, _weth];

        uint8[] memory _fbDexIdsFB = new uint8[](1);
        _fbDexIdsFB[0] = 0;
        uint8[] memory _fbDexIdsQuick = new uint8[](1);
        _fbDexIdsQuick[0] = 1;
        setDexIds(_fbDexIdsFB, _fbDexIdsQuick);

        atm = IERC20(_atm);
        ausd = IERC20(_ausd);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);

        WBNB = _weth;
    }

    // Swap functions
    function swapUsdcToAusd(uint256 _amount, uint256 _minOut)
    external
    override
    nonReentrant
    {

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.safeApprove(address(fbRouter), 0);
        usdc.safeApprove(address(fbRouter), _amount);

        uint balancethis = usdc.balanceOf(address(this));
        uint ausdbal = ausd.balanceOf(address(this));

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = fbAusdPair.getReserves();

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            _minOut,
            fbUsdcAusdPairPath,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapUsdcToAtm(uint256 _amount, uint256 _minOut)
    external
    override
    nonReentrant
    {
        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.safeApprove(address(fbRouter), 0);
        usdc.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            _minOut,
            fbUsdcAtmPairPath,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapAtmToUsdc(uint256 _amount, uint256 _minOut)
    external
    override
    nonReentrant
    {
        atm.safeTransferFrom(msg.sender, address(this), _amount);
        atm.safeApprove(address(fbRouter), 0);
        atm.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            _minOut,
            fbAtmPairPath,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapAusdToUsdc(uint256 _amount, uint256 _minOut)
    external
    override
    nonReentrant
    {
        ausd.safeTransferFrom(msg.sender, address(this), _amount);
        ausd.safeApprove(address(fbRouter), 0);
        ausd.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            _minOut,
            fbAusdPairPath,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function swapWethToUsdc(uint256 _amount, uint256 _minOut)
    external
    override
    nonReentrant
    {
        weth.safeTransferFrom(msg.sender, address(this), _amount);
        weth.safeApprove(address(fbRouter), 0);
        weth.safeApprove(address(fbRouter), _amount);

        fbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amount,
            _minOut,
            fbWethPairPath,
            msg.sender,
            block.timestamp + TIMEOUT
        );
    }

    function zapInAtm(
        uint256 _amount,
        uint256 _minUsdc,
        uint256 _minLp
    ) external override nonReentrant returns (uint256) {


        atm.safeTransferFrom(msg.sender, address(this), _amount);

        uint256[] memory _amounts = new uint256[](3);
        _amounts[0] = _amount; // amount_from (ATM)
        _amounts[1] = _minUsdc; // minTokenB (USDC)
        _amounts[2] = _minLp; // minLp

        uint256 _lpAmount = _zapInToken(
            address(atm),
            _amounts,
            address(fbAtmPair),
            true
        );



        require(_lpAmount > 0, "Exchange: No lp");
        require(
            fbAtmPair.transfer(msg.sender, _lpAmount),
            "Exchange: Faild to transfer"
        );

        return _lpAmount;
    }

    function zapInUsdc(
        uint256 _amount,
        uint256 _minAtm,
        uint256 _minLp
    ) external override nonReentrant returns (uint256) {
        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        uint256[] memory _amounts = new uint256[](3);
        _amounts[0] = _amount; // amount_from (USDC)
        _amounts[1] = _minAtm; // minTokenB (ATM)
        _amounts[2] = _minLp; // minLp

        uint256 _lpAmount = _zapInToken(
            address(usdc),
            _amounts,
            address(fbAtmPair),
            true
        );

        require(_lpAmount > 0, "Exchange: No lp");
        require(
            fbAtmPair.transfer(msg.sender, _lpAmount),
            "Exchange: Faild to transfer"
        );

        return _lpAmount;
    }

    function zapOutAtm(uint256 _amount, uint256 _minOut)
    external
    override
    nonReentrant
    returns (uint256)
    {
        require(
            fbAtmPair.transferFrom(msg.sender, address(this), _amount),
            "Exchange: Failed to transfer pair"
        );


        uint256 _atmAmount = _zapOut(
            address(fbAtmPair),
            _amount,
            address(atm),
            _minOut
        );



        require(_atmAmount > 0, "Exchange: Atm amount is 0");
        atm.safeTransfer(msg.sender, _atmAmount);
        return _atmAmount;
    }

    // Setters
    function setContracts(
        address _router,
        address _factory,
        address _atmPair,
        address _ausdPair
    ) public onlyOwner {

        if (_router != address(0)) {
            fbRouter = IUniswapV2Router(_router);
        }
        if (_factory != address(0)) {
            fbFactory = IUniswapV2Factory(_factory);
        }
        if (_atmPair != address(0)) {
            fbAtmPair = IUniswapV2Pair(_atmPair);
        }
        if (_ausdPair != address(0)) {
            fbAusdPair = IUniswapV2Pair(_ausdPair);
        }

        emit LogSetContracts(
            _router,
            _factory,
            _atmPair,
            _ausdPair
        );
    }

    function setPairPaths(
        address[] memory _AtmPairPath,
        address[] memory _AusdPairPath,
        address[] memory _WethPairPath
    ) public onlyOwner {
        fbAtmPairPath = _AtmPairPath;
        fbAusdPairPath = _AusdPairPath;
        fbWethPairPath = _WethPairPath;

        emit LogSetPairPaths(fbAtmPairPath, fbAusdPairPath, fbWethPairPath);
    }

    function setDexIds(
        uint8[] memory _fbDexIdsFB,
        uint8[] memory _fbDexIdsQuick
    ) public onlyOwner {
        fbDexIdsFB = _fbDexIdsFB;
        fbDexIdsQuick = _fbDexIdsQuick;

        emit LogSetDexIds(fbDexIdsFB, fbDexIdsQuick);
    }

    function _zapInToken(address _from, uint[] memory amounts, address _to, bool transferResidual) private returns (uint256 lpAmt) {
        _approveTokenIfNeeded(_from);

        if (_from == IUniswapV2Pair(_to).token0() || _from == IUniswapV2Pair(_to).token1()) {
            // swap half amount for other
            address other;
            uint256 sellAmount;
            {
                address token0 = IUniswapV2Pair(_to).token0();
                address token1 = IUniswapV2Pair(_to).token1();
                other = _from == token0 ? token1 : token0;
                sellAmount = calculateSwapInAmount(_to, _from, amounts[0], token0);
            }
            uint otherAmount = _swap(_from, sellAmount, other, address(this), _to);
            require(otherAmount >= amounts[1], "Zap: Insufficient Receive Amount");


            lpAmt = _pairDeposit(_to, _from, other, amounts[0].sub(sellAmount), otherAmount, address(this), false, transferResidual);

        } else {
            uint bnbAmount = _swapTokenForBNB(_from, amounts[0], address(this), address(0));
            lpAmt = _swapBNBToLp(IUniswapV2Pair(_to), bnbAmount, address(this), 0, transferResidual);
        }

        require(lpAmt >= amounts[2], "Zap: High Slippage In");
        return lpAmt;
    }

    function _zapOut (address _from, uint amount, address _toToken, uint256 _minTokensRec) private returns (uint256) {
        _approveTokenIfNeeded(_from);

        address token0;
        address token1;
        uint256 amountA;
        uint256 amountB;
        {
            IUniswapV2Pair pair = IUniswapV2Pair(_from);
            token0 = pair.token0();
            token1 = pair.token1();
            (amountA, amountB) = fbRouter.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);
        }

        uint256 tokenBought;
        _approveTokenIfNeeded(token0);
        _approveTokenIfNeeded(token1);
        if (_toToken == WBNB) {
            address _lpOfFromAndTo = WBNB == token0 || WBNB == token1 ? _from : address(0);
            tokenBought = _swapTokenForBNB(token0, amountA, address(this), _lpOfFromAndTo);
            tokenBought = tokenBought + (_swapTokenForBNB(token1, amountB, address(this), _lpOfFromAndTo));
        } else {
            address _lpOfFromAndTo = _toToken == token0 || _toToken == token1 ? _from : address(0);
            tokenBought = _swap(token0, amountA, _toToken, address(this), _lpOfFromAndTo);
            tokenBought = tokenBought + (_swap(token1, amountB, _toToken, address(this), _lpOfFromAndTo));

        }


        require(tokenBought >= _minTokensRec, "Zap: High Slippage Out");
        if (_toToken == WBNB) {
            TransferHelper.safeTransferETH(address(this), tokenBought);
        } else {
            IERC20(_toToken).safeTransfer(address(this), tokenBought);
        }

        return tokenBought;
    }

    function _approveTokenIfNeeded(address token) private {
        if (IERC20(token).allowance(address(this), address(fbRouter)) == 0) {
            IERC20(token).safeApprove(address(fbRouter), 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        }
    }


    function _swapTokenForBNB(address token, uint amount, address _receiver, address lpTokenBNB) private returns (uint) {
        if (token == WBNB) {
            _transferToken(WBNB, _receiver, amount);
            return amount;
        }

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;
        uint[] memory amounts;
        if (path.length > 0) {
            amounts = fbRouter.swapExactTokensForETH(amount, 1, path, _receiver, block.timestamp);
        } else if (lpTokenBNB != address(0)) {
            path = new address[](1);
            path[0] = lpTokenBNB;
            amounts = fbRouter.swapExactTokensForETH(amount, 1, path, _receiver, block.timestamp);
        } else {
            revert("FireBirdZap: !path TokenBNB");
        }

        return amounts[amounts.length - 1];
    }

    function _swap(address _from, uint _amount, address _to, address _receiver, address _lpOfFromTo) internal returns (uint) {
        if (_from == _to) {
            if (_receiver != address(this)) {
                IERC20(_from).safeTransfer(_receiver, _amount);
            }
            return _amount;
        }
        address[] memory path = new address[](2);
        path[0] = _from;
        path[1] = _to;
        uint[] memory amounts;
        if (path.length > 0) {// use fireBird
            amounts = fbRouter.swapExactTokensForTokens(_amount, 1, path, _receiver, block.timestamp);
        } else if (_lpOfFromTo != address(0)) {
            path = new address[](1);
            path[0] = _lpOfFromTo;
            amounts = fbRouter.swapExactTokensForTokens(_amount, 1, path, _receiver, block.timestamp);
        } else {
            revert("FireBirdZap: !path swap");
        }

        return amounts[amounts.length - 1];
    }

    function _transferToken(address token, address to, uint amount) internal {
        if (amount == 0) {
            return;
        }

        if (token == WBNB) {
            IWETH(WBNB).withdraw(amount);
            if (to != address(this)) {
                TransferHelper.safeTransferETH(to, amount);
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        return;
    }

    function calculateSwapInAmount(address pair, address tokenIn, uint256 userIn, address pairToken0) internal view returns (uint256) {
        (uint32 tokenWeight0, uint32 tokenWeight1) = (50,50); // ????????????????????????????
        uint swapFee = 0; // ?????????????????????
        if (tokenWeight0 == 50) {
            (uint256 res0, uint256 res1,) = IUniswapV2Pair(pair).getReserves();
            uint reserveIn = tokenIn == pairToken0 ? res0 : res1;
            uint256 rMul = uint256(10000).sub(uint256(swapFee));

            return _getExactSwapInAmount(reserveIn, userIn, rMul);
        } else {
            uint256 otherWeight = tokenIn == pairToken0 ? uint256(tokenWeight1) : uint256(tokenWeight0);
            return userIn.mul(otherWeight).div(100);
        }
    }

    function _getExactSwapInAmount(
        uint256 reserveIn,
        uint256 userIn,
        uint256 rMul
    ) internal pure returns (uint256) {
        return Babylonian.sqrt(reserveIn.mul(userIn.mul(40000).mul(rMul) + reserveIn.mul(rMul.add(10000)).mul(rMul.add(10000)))).sub(reserveIn.mul(rMul.add(10000))) / (rMul.mul(2));
    }

    function _pairDeposit(
        address _pair,
        address _poolToken0,
        address _poolToken1,
        uint256 token0Bought,
        uint256 token1Bought,
        address receiver,
        bool isfireBirdPair,
        bool transferResidual
    ) internal returns (uint256 lpAmt) {
        _approveTokenIfNeeded(_poolToken0);
        _approveTokenIfNeeded(_poolToken1);

        uint256 amountA;
        uint256 amountB;
        (amountA, amountB, lpAmt) = fbRouter.addLiquidity(_poolToken0, _poolToken1, token0Bought, token1Bought, 1, 1, receiver, block.timestamp);

        uint amountAResidual = token0Bought.sub(amountA);
        if (transferResidual || amountAResidual > token0Bought.mul(maxResidual).div(10000)) {
            if (amountAResidual > 0) {
                //Returning Residue in token0, if any.
                _transferToken(_poolToken0, msg.sender, amountAResidual);
            }
        }

        uint amountBRedisual = token1Bought.sub(amountB);
        if (transferResidual || amountBRedisual > token1Bought.mul(maxResidual).div(10000)) {
            if (amountBRedisual > 0) {
                //Returning Residue in token1, if any
                _transferToken(_poolToken1, msg.sender, amountBRedisual);
            }
        }

        return lpAmt;
    }

    function _swapBNBToLp(IUniswapV2Pair pair, uint amount, address receiver, uint _minTokenB, bool transferResidual) private returns (uint256 lpAmt) {
        address lp = address(pair);

        // Lp
        if (pair.token0() == WBNB || pair.token1() == WBNB) {
            address token = pair.token0() == WBNB ? pair.token1() : pair.token0();
            uint swapValue = calculateSwapInAmount(lp, WBNB, amount, pair.token0());
            uint tokenAmount = _swapBNBForToken(token, swapValue, address(this), lp);
            require(tokenAmount >= _minTokenB, "Zap: Insufficient Receive Amount");

            uint256 wbnbAmount = amount.sub(swapValue);
            IWETH(WBNB).deposit{value : wbnbAmount}();
            lpAmt = _pairDeposit(lp, WBNB, token, wbnbAmount, tokenAmount, receiver, false, transferResidual);
        } else {
            address token0 = pair.token0();
            address token1 = pair.token1();
            uint token0Amount;
            uint token1Amount;
            {
                uint32 tokenWeight0 = 50; // ??????????????????????
                uint swap0Value = amount.mul(uint(tokenWeight0)).div(100);
                token0Amount = _swapBNBForToken(token0, swap0Value, address(this), address(0));
                token1Amount = _swapBNBForToken(token1, amount.sub(swap0Value), address(this), address(0));
            }

            lpAmt = _pairDeposit(lp, token0, token1, token0Amount, token1Amount, receiver, false, transferResidual);
        }
    }

    function _swapBNBForToken(address token, uint value, address _receiver, address lpBNBToken) private returns (uint) {
        if (token == WBNB) {
            IWETH(WBNB).deposit{value : value}();
            if (_receiver != address(this)) {
                IERC20(WBNB).safeTransfer(_receiver, value);
            }
            return value;
        }
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        uint[] memory amounts;
        if (path.length > 0) {
            amounts = fbRouter.swapExactETHForTokens{value : value}(1, path, _receiver, block.timestamp);
        } else if (lpBNBToken != address(0)) {
            path = new address[](1);
            path[0] = lpBNBToken;
            amounts = fbRouter.swapExactETHForTokens{value : value}(1, path, _receiver, block.timestamp);
        } else {
            revert("FireBirdZap: !path BNBToken");
        }

        return amounts[amounts.length - 1];
    }

}