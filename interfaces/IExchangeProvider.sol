// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IExchangeProvider {
    function swapUsdcToAusd(uint256 _amount, uint256 _minOut) external;

    function swapUsdcToAtm(uint256 _amount, uint256 _minOut) external;

    function swapAtmToUsdc(uint256 _amount, uint256 _minOut) external;

    function swapAusdToUsdc(uint256 _amount, uint256 _minOut) external;

    function zapInAtm(
        uint256 _amount,
        uint256 _minUsdc,
        uint256 _minLp
    ) external returns (uint256);

    function zapInUsdc(
        uint256 _amount,
        uint256 _minAtm,
        uint256 _minLp
    ) external returns (uint256);

    function zapOutAtm(uint256 _amount, uint256 _minOut)
        external
        returns (uint256);

    function swapWethToUsdc(uint256 _amount, uint256 _minOut) external;
}
