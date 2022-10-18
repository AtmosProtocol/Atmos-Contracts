// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IDepository {
    function investingAmt() external view returns (uint256);

    function excessCollateralSafetyMargin() external view returns (uint256);

    function transferCollatTo(address _to, uint256 _amt) external;

    function transferAtmTo(address _to, uint256 _amt) external;

    function globalCollateralBalance() external view returns (uint256);

    function getInvestingAmt() external view returns(uint256);
}
