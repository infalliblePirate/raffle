// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * Timelock contract that enforces a delay on governance actions
 */
contract RaffleTimelock is TimelockController {
    /**
     * @param minDelay minimum delay in seconds before execution (like 2 days = 172800)
     * @param proposers list of addresses that can propose (RaffleGovernor)
     * @param executors list of addresses that can execute (address(0) for anyone)
     * @param admin optional admin address
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}
}