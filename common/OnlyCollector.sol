// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract OnlyCollector is Ownable {
    address public collector;

    event CollectorUpdated(address indexed collector);

    modifier onlyCollector() {
        require(msg.sender == collector, "OnlyCollector: onlyCollector");
        _;
    }

    modifier onlyCollectorOrOwner() {
        require(
            msg.sender == collector || msg.sender == owner(),
            "OnlyCollector: onlyCollectorOrOwner"
        );
        _;
    }

    constructor(address _collector) {
        setCollector(_collector);
    }

    function setCollector(address _collector) public onlyOwner {
        require(_collector != address(0), "OnlyCollector: invalid address");
        collector = _collector;
        emit CollectorUpdated(collector);
    }
}
