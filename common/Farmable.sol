// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../common/AtmosProtocol.sol";
import "../common/RunExchange.sol";
import "../interfaces/IAtmosERC20.sol";
import "../interfaces/IAtmosChef.sol";

contract Farmable is AtmosProtocol, Initializable {
    using SafeERC20 for IERC20;
    IAtmosChef public farm;

    event FarmUpdated(address farm);
    event FarmDeposited(uint256 pid, uint256 amount, address to);
    event FarmHarvested(uint256 pid);
    event FarmClaimed(uint256 pid, uint256 vid);
    event FarmWithdrawnAndHarvested(uint256 pid, uint256 amount);

    function farmDeposit(
        uint256 pid,
        uint256 amount,
        address to
    ) public onlyOwnerOrOperator {
        require(amount > 0, "zero amount");
        IERC20 token = IERC20(farm.getLpToken(pid));

        require(token.balanceOf(address(this)) >= amount, "Not enough balance");
        token.safeApprove(address(farm), 0);
        token.safeApprove(address(farm), amount);
        farm.deposit(pid, amount, to);
        emit FarmDeposited(pid, amount, to);
    }

    function farmHarvest(uint256 pid) public onlyOwnerOrOperator {
        farm.harvest(pid);
        emit FarmHarvested(pid);
    }

    function farmHarvestWithPenalty(uint256 pid) public onlyOwnerOrOperator {
        farm.harvestWithPenalty(pid);
        emit FarmHarvested(pid);
    }

    function farmWithdrawAndHarvest(uint256 pid, uint256 amount)
        public
        onlyOwnerOrOperator
    {
        require(amount > 0, "Farmable: Zero amount");
        farm.withdrawAndHarvest(pid, amount);
        emit FarmWithdrawnAndHarvested(pid, amount);
    }

    function setFarm(address _farm) public onlyOwner {
        require(_farm != address(0), "Framable: Zero address");
        farm = IAtmosChef(_farm);
        emit FarmUpdated(_farm);
    }

    function transferTo(
        address _receiver,
        address _token,
        uint256 _amount
    ) public onlyOwner {
        IERC20 token = IERC20(_token);
        require(
            token.balanceOf(address(this)) >= _amount,
            "Shredder: Not enough balance"
        );
        require(_amount > 0, "Zero amount");
        token.safeTransfer(_receiver, _amount);
    }
}
