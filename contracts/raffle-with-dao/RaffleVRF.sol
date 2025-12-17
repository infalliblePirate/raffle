// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import "./RaffleCore.sol";

abstract contract RaffleVRF is RaffleCore, VRFConsumerBaseV2Plus {
   
    // The default is 3, but you can set this higher.
    uint16 public requestConfirmations = 1;
    
    // Cannot exceed VRFCoordinatorV2_5.MAX_NUM_WORDS.
    uint32 public numWords = 1;

    event RandomRequested(uint256 indexed gameId, uint256 requestId);
    event RandomFulfilled(uint256 indexed gameId, uint256 randomNumber);

    function requestRandom() public onlyContractOwner {
        require(_canTriggerEndGame(), "Conditions not met");
        _requestRandomInternal();
    }

    function _requestRandomInternal() internal {
        uint256 gid = gameId;
        if (randomResult[gid] != 0) return;
        require(gameState[gid] == GameState.Active, "Game not active");

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
                )
            })
        );
        lastRequestId = requestId;

        gameIdForRequest[requestId] = gid;

        _changeGameState(gid, GameState.RandomRequested);
        emit RandomRequested(gid, requestId);
    }

    function setSubscription(uint subId) external onlyContractOwner {
        subscriptionId = subId;
    }

    // callback used by vpf coordinator
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal virtual override {
        uint256 targetGameId = gameIdForRequest[requestId];
        randomResult[targetGameId] = randomWords[0];

        emit RandomFulfilled(targetGameId, randomWords[0]);
    }
}
