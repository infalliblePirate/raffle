// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RaffleGovToken is ERC20, ERC20Permit, ERC20Burnable, ERC20Votes, Ownable {
        constructor(
        uint256 initialSupply
    ) 
        ERC20("Raffle Governance Token", "RGT") 
        ERC20Permit("Raffle Governance Token") 
        Ownable(msg.sender) 
    {
        _mint(msg.sender, initialSupply);
    }

    /**
     * Owner will be the Timelock contract, minting requires governance approval
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    // The following functions are overrides required by Solidity.

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}