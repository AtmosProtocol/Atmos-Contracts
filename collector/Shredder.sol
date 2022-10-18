// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../common/AtmosProtocol.sol";
import "../common/RunExchange.sol";
import "../common/Farmable.sol";
import "../interfaces/IAtmosERC20.sol";
import "../interfaces/IAtmosChef.sol";

contract Shredder is AtmosProtocol, Initializable, RunExchange, Farmable {
    IAtmosERC20 public atm;
    IUniswapV2Pair public atmPair;

    event LogSetAtm(address atm, address atmPair);
    event LogBurn(uint256 lpAmount, uint256 atmBurnt);

    function init(
        address _atmPair,
        address _atm,
        address _exchangeProvider
    ) public initializer onlyOwner {
        setAtm(_atm, _atmPair);
        setExchangeProvider(_exchangeProvider);
    }

    function burnLp(uint256 _amount) external onlyOwnerOrOperator {
        uint256 _lpBalance = atmPair.balanceOf(address(this));
        require(_lpBalance >= _amount, "Shredder: amount > balance");

        require(
            atmPair.approve(address(exchangeProvider), 0),
            "Shredder: failed to approve"
        );
        require(
            atmPair.approve(address(exchangeProvider), _lpBalance),
            "Shredder: failed to approve"
        );

        uint256 _atmAmount = exchangeProvider.zapOutAtm(_amount, 0);

        atm.burn(address(this), _atmAmount);

        emit LogBurn(_amount, _atmAmount);
    }

    function setAtm(address _atm, address _atmPair) public onlyOwner {
        require(
            _atm != address(0) && _atmPair != address(0),
            "Shredder: invalid atm address"
        );
        atm = IAtmosERC20(_atm);
        atmPair = IUniswapV2Pair(_atmPair);
        emit LogSetAtm(_atm, _atmPair);
    }
}
