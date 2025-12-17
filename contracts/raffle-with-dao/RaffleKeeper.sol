// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RaffleVRF.sol";

import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";

abstract contract RaffleKeeper is
    RaffleVRF,
    ILogAutomation,
    AutomationCompatibleInterface
{
    event AutomationTriggered(uint8 action, string reason, uint256 gameId);

    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        if (!automationEnabled) return (false, bytes(""));

        uint256 gid = gameId;
        if (
            gameState[gid] != GameState.Active ||
            randomResult[gid] != 0 ||
            !_canTriggerEndGame()
        ) {
            return (false, bytes(""));
        }

        return (
            true,
            abi.encode(uint8(1), uint256(0), "valid_end_request_random")
        );
    }

    function checkLog(
        Log calldata log,
        bytes memory
    ) external view returns (bool upkeepNeeded, bytes memory performData) {
        // on RandomFulfilled(uint256 gameid, uint256 randomNumber);
        uint256 gid = uint256(log.topics[1]);

        if (
            gameState[gid] != GameState.RandomRequested ||
            randomResult[gid] == 0 ||
            winner[gid] != address(0)
        ) {
            return (false, bytes(""));
        }

        uint256 winnerIndex = _findWinnerIndex(gid);

        return (true, abi.encode(uint8(2), winnerIndex, "random_winner_ready"));
    }

    function _findWinnerIndex(uint256 gid) internal view returns (uint256) {
        uint256 winningPoint = randomResult[gid] % poolUSD[gid];

        for (uint256 i = 0; i < winningRanges[gid].length; i++) {
            UserWinningRange memory range = winningRanges[gid][i];
            if (winningPoint >= range.min && winningPoint < range.max) {
                return i;
            }
        }
        revert("Winner not found");
    }

    function performUpkeep(
        bytes calldata performData
    ) external override(AutomationCompatibleInterface, ILogAutomation) {
        require(automationEnabled, "Automation disabled");

        (uint8 action, uint256 index, bytes memory reasonBytes) = abi.decode(
            performData,
            (uint8, uint256, bytes)
        );
        if (action == 1) {
            _requestRandomInternal();
            emit AutomationTriggered(1, string(reasonBytes), gameId);
        } else if (action == 2) {
            _keeperEndAndStartGame(index);
            emit AutomationTriggered(2, string(reasonBytes), gameId);
        } else {
            revert("Unknown upkeep action");
        }
    }

    function _keeperEndAndStartGame(uint256 index) internal {
        _endGameInternal(index);
        _startGameInternal();
    }

    function setAutomationEnabled(bool enabled) external onlyContractOwner {
        automationEnabled = enabled;
    }
}
