// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAtmosERC20 is IERC20 {
    function burn(address _sender, uint256 _amt) external;

    function mintByCollector(address _to, uint256 _amt) external;

    function mintByFarm(address _to, uint256 _amt) external;
}
