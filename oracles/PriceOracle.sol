// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IFluxPriceFeed.sol";
import "../interfaces/IPriceOracle.sol";
import "../common/AtmosProtocol.sol";
import "./TwapOracle.sol";

contract PriceOracle is AtmosProtocol, IPriceOracle {
    IFluxPriceFeed public immutable fluxOracle;
    TwapOracle public ausdCollatTwapOracle;
    TwapOracle public atmCollatTwapOracle;

    event AusdOracleUpdated(address indexed newOracle);
    event AtmOracleUpdated(address indexed newOracle);

    constructor(
        address _FluxPriceFeedAddress,
        address _ausdCollatTwapOracle,
        address _atmCollatTwapOracle
    ) {
        fluxOracle = IFluxPriceFeed(_FluxPriceFeedAddress);
        setAusdOracle(_ausdCollatTwapOracle);
        setAtmOracle(_atmCollatTwapOracle);
    }

    function collatPrice() public view override returns (uint256) {
        uint256 _price = uint256(fluxOracle.latestAnswer());
        uint8 _decimals = 8;
        return (_price * PRICE_PRECISION) / (10**_decimals);
    }

    function ausdPrice() external view override returns (uint256) {
        uint256 _collatPrice = collatPrice();
        uint256 _ausdPrice = ausdCollatTwapOracle.consult(AUSD_PRECISION);
        require(_ausdPrice > 0, "Oracle: invalid ausd price");

        return (_collatPrice * _ausdPrice) / PRICE_PRECISION;
    }

    function atmPrice() external view override returns (uint256) {
        uint256 _collatPrice = collatPrice();
        uint256 _atmPrice = atmCollatTwapOracle.consult(ATM_PRECISION);
        require(_atmPrice > 0, "Oracle: invalid atm price");
        return (_collatPrice * _atmPrice) / PRICE_PRECISION;
    }

    function setAusdOracle(address _oracle) public onlyOwner {
        ausdCollatTwapOracle = TwapOracle(_oracle);
        emit AusdOracleUpdated(_oracle);
    }

    function setAtmOracle(address _oracle) public onlyOwner {
        atmCollatTwapOracle = TwapOracle(_oracle);
        emit AtmOracleUpdated(_oracle);
    }
}
