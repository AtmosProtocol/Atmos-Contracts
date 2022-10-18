// SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../common/OnlyCollector.sol";
import "../interfaces/IAtmosERC20.sol";

import "hardhat/console.sol";

abstract contract AtmosERC20 is ERC20, OnlyCollector, IAtmosERC20 {
    event LogAddBurnAddress(address burnAddress);
    event LogRemoveBurnAddress(address burnAddress);
    event LogAddFarm(address farm);
    event LogRemoveFarm(address farm);
    event LogBurn(address sender, uint256 amount);
    event LogMint(address sender, uint256 amount);

    mapping(address => bool) public burnAddress;
    mapping(address => bool) public farms;

    modifier onlyBurnable() {
        require(burnAddress[msg.sender], "AtmosERC20: Not burnable");
        _;
    }

    modifier onlyFarm() {
        require(farms[msg.sender], "AtmosERC20: Not farm");
        _;
    }

    constructor(
        string memory _tokenName,
        string memory _tokenSymbol,
        address _collector
    ) ERC20(_tokenName, _tokenSymbol) OnlyCollector(_collector) {
        setCollector(_collector);
    }

    function burn(address _sender, uint256 _amt)
        external
        override
        onlyBurnable
    {
        _burn(_sender, _amt);
        emit LogBurn(_sender, _amt);
    }

    function mintByCollector(address _to, uint256 _amt) public override onlyCollector {
        _mint(_to, _amt);
        emit LogMint(_to, _amt);
    }

    function mintByFarm(address _to, uint256 _amt) public virtual override;

    function addBurnAddress(address _burnAddress) external onlyOwner {
        burnAddress[_burnAddress] = true;
        emit LogAddBurnAddress(_burnAddress);
    }

    function removeBurnAddress(address _burnAddress) external onlyOwner {
        delete burnAddress[_burnAddress];
        emit LogRemoveBurnAddress(_burnAddress);
    }

    function addFarm(address _farm) external onlyOwner {
        farms[_farm] = true;
        emit LogAddFarm(_farm);
    }

    function removeFarm(address _farm) external onlyOwner {
        delete farms[_farm];
        emit LogRemoveFarm(_farm);
    }
}
