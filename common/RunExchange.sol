// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IExchangeProvider.sol";

abstract contract RunExchange is Ownable, Initializable {
    IExchangeProvider public exchangeProvider;

    event LogSetExchangeProvider(address indexed exchangeProvider);

    function setExchangeProvider(address _exchangeProvider) public onlyOwner {
        require(_exchangeProvider != address(0), "RunExchange: invalid address");
        exchangeProvider = IExchangeProvider(_exchangeProvider);
        emit LogSetExchangeProvider(_exchangeProvider);
    }
}
