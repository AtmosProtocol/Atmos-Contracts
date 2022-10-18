// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IPriceOracle {
    function collatPrice() external view returns (uint256);

    function ausdPrice() external view returns (uint256);

    function atmPrice() external view returns (uint256);
}
