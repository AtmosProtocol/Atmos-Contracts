// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./AtmosERC20.sol";

contract aUSD is AtmosERC20 {
    uint256 public constant GENESIS_SUPPLY = 2 ether;

    constructor(address _collector) AtmosERC20("testUSD", "tUSD", _collector) {
        _mint(msg.sender, GENESIS_SUPPLY);
    }

    function mintByFarm(address _to, uint256 _amt) public override onlyFarm {
        require(false, "Farm can't mint");
        emit LogMint(_to, _amt);
    }
}
