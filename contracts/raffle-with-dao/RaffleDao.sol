// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RaffleKeeper.sol";

// raffleStorage -> raffleGovernance -> raffleCore -> raffleVRF -> raffleKeeper
// raffleGovernance sets deployed: governor, govToken, timelock
contract RaffleDao is RaffleKeeper {
    constructor(
        address owner_,
        // governance
        address gov_,
        address plat_,
        address found_,
        // financial
        address swapRouter_,
        address weth_,
        // vrf
        address vrfCoordinator_,
        uint256 subId_
    )
        RaffleStorage(owner_, gov_, plat_, found_)
        RaffleCore(swapRouter_, weth_)
        VRFConsumerBaseV2Plus(vrfCoordinator_)
    {
        subscriptionId = subId_;
        
        // in VRFConsumerBaseV2Plus ConfirmedOwner sets the owner to msg.sender by default
        // if owner_ is not the deployer - transfer the ownership
        if (msg.sender != owner_) {
            // Note: owner_ will need to call acceptOwnership() to finish the sync
            transferOwnership(owner_); 
        }
    }

    function transferContractOwnership(address to) external onlyContractOwner {
        require(to != address(0), "Zero address");

        contractOwner = to;
        transferOwnership(to);
    }

}
