// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./AtmosERC20.sol";

contract ATM is AtmosERC20 {
    uint256 public constant GENESIS_SUPPLY = 25_000_000 ether; // minted at genesis for liquidity pool seeding
    uint256 public constant COMMUNITY_REWARD_ALLOCATION = 75_000_000 ether;

    uint256 public atmMintedByFarm;

    constructor(
        address _collector
    ) AtmosERC20("Test Share Token", "TST", _collector) {
        _mint(msg.sender, GENESIS_SUPPLY);
    }

    function mintByFarm(address _to, uint256 _amt) public override onlyFarm {
        require(_amt > 0, "ATM: Aero amount");
        require(_to != address(0), "ATM: Zero address");
        require(
            atmMintedByFarm < COMMUNITY_REWARD_ALLOCATION,
            "ATM: Reward alloc zero"
        );

        if (atmMintedByFarm + _amt > COMMUNITY_REWARD_ALLOCATION) {
            uint256 amtLeft = COMMUNITY_REWARD_ALLOCATION - atmMintedByFarm;
            atmMintedByFarm += amtLeft;
            _mint(_to, amtLeft);
        } else {
            atmMintedByFarm += _amt;
            _mint(_to, _amt);
        }

        emit LogMint(_to, _amt);
    }
}
