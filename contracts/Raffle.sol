// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/ILogAutomation.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "hardhat/console.sol";

interface IWETH {
    function withdraw(uint256) external;
} // to unwrap weth to eth

contract Raffle is
    VRFConsumerBaseV2Plus,
    ILogAutomation,
    AutomationCompatibleInterface
{
    enum GameState {
        Active,
        RandomRequested,
        Ended
    }

    struct UserWinningRange {
        address user;
        uint256 min;
        uint256 max;
    }

    mapping(uint256 => UserWinningRange[]) public winningRanges;

    uint32 public constant MAX_SUPPORTED_TOKENS = 100;
    uint32 public constant MAX_PARTICIPATED_USERS = 2;

    uint32 public supportedTokensCount;
    uint8 public MIN_PARTICIPATION_USD_DEPOSIT = 0;

    // keeper config (triggers)
    bool public automationEnabled;
    uint256 public minUsersToTrigger = MAX_PARTICIPATED_USERS;
    uint256 public maxGameDuration = 24 hours;
    uint256 public minPoolUSDToTrigger = 10_000 * 1e18;

    uint256 public gameId;
    mapping(uint256 => uint256) public poolUSD;
    mapping(uint256 => address[]) public users;
    mapping(uint256 => mapping(address => bool)) private _hasParticipated;
    mapping(uint256 => mapping(address => uint256)) public tokenBalances;
    mapping(uint256 => address[]) public playedTokens;
    mapping(uint256 => address) public winner;
    mapping(uint256 => GameState) public gameState;

    mapping(uint256 => uint256) public randomResult;
    mapping(uint256 => uint256) public gameIdForRequest;

    // for keepers
    mapping(uint256 => uint256) public gameStart;

    mapping(address => address) private _tokenFeeds;

    // The gas lane to use, which specifies the maximum gas price to bump to.
    // For a list of available gas lanes on each network,
    // see https://docs.chain.link/vrf/v2-5/supported-networks
    bytes32 public keyHash =
        0x3f631d5ec60a0ce8203ca649b3f89f4df96dd01bd96763dbb252c5a3c5590f8a;

    address public constant coordinatorAddr =
        0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;

    // Depends on the number of requested values that you want sent to the
    // fulfillRandomWords() function. Storing each word costs about 20,000 gas,
    // so 100,000 is a safe default for this example contract. Test and adjust
    // this limit based on the network that you select, the size of the request,
    // and the processing of the callback request in the fulfillRandomWords()
    // function.
    uint32 public callbackGasLimit = 60_000;

    // The default is 3, but you can set this higher.
    uint16 public requestConfirmations = 1;

    // Cannot exceed VRFCoordinatorV2_5.MAX_NUM_WORDS.
    uint32 public numWords = 1;

    uint256 public subscriptionId;

    ISwapRouter public swapRouter =
        ISwapRouter(0x3344BBDCeb8f6fb52de759c127E4A44EFb40432A);
    address public WETH;

    error NotSupportedToken();
    error ZeroAmount();
    error NoActiveRound();
    error InvalidPrice();
    error PriceStale();
    error IncorrectWinner();
    error NoPoolValue();
    error SwapFailed();

    event Deposit(
        address indexed sender,
        address indexed token,
        uint256 tokenAmount,
        uint256 usdValue
    );
    event GameEnded(uint256 indexed gameId, address winner);
    event RandomRequested(uint256 indexed gameId, uint256 requestId);
    event RandomFulfilled(uint256 indexed gameId, uint256 randomNumber);
    event AutomationTriggered(uint8 action, string reason, uint256 gameId);
    event WinnerClaimed(
        uint256 indexed gameId,
        address winner,
        address token,
        uint256 amount
    );
    event GameStateChanged(
        uint256 gameId,
        GameState oldState,
        GameState newState
    );

    uint256 public lastRequestId;

    constructor(
        uint256 subscriptionId_
    ) VRFConsumerBaseV2Plus(coordinatorAddr) {
        subscriptionId = subscriptionId_;
    }

    function addTokenFeed(address token, address feed) external onlyOwner {
        bool isNew = _tokenFeeds[token] == address(0);

        if (isNew) {
            require(
                supportedTokensCount < MAX_SUPPORTED_TOKENS,
                "Max token limit reached"
            );
            supportedTokensCount++;
        }

        _tokenFeeds[token] = feed;
    }

    function startGame() public onlyOwner {
        _startGameInternal();
    }

    function _startGameInternal() internal {
        gameId++;
        gameStart[gameId] = block.timestamp;
        gameState[gameId] = GameState.Active;
    }

    function deposit(
        address token,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (amount == 0) {
            revert ZeroAmount();
        }
        if (_tokenFeeds[token] == address(0)) {
            revert NotSupportedToken();
        }
        if (gameState[gameId] != GameState.Active) {
            revert NoActiveRound();
        }

        try
            IERC20Permit(token).permit(
                msg.sender,
                address(this),
                amount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}

        IERC20(token).transferFrom(msg.sender, address(this), amount);

        if (tokenBalances[gameId][token] == 0) {
            playedTokens[gameId].push(token);
        }
        tokenBalances[gameId][token] += amount;

        uint256 usdValue = _getTokenValueInUSD(token, amount);
        require(
            usdValue >= MIN_PARTICIPATION_USD_DEPOSIT,
            "Usd tokens equivalent must be >= 10$"
        );

        if (!_hasParticipated[gameId][msg.sender]) {
            require(
                users[gameId].length <= MAX_PARTICIPATED_USERS,
                "User limit per round reached"
            );
            users[gameId].push(msg.sender);
            _hasParticipated[gameId][msg.sender] = true;
        }

        winningRanges[gameId].push(
            UserWinningRange(
                msg.sender,
                poolUSD[gameId],
                poolUSD[gameId] + usdValue
            )
        );
        poolUSD[gameId] += usdValue;

        emit Deposit(msg.sender, token, amount, usdValue);
    }

    // todo: add price stale
    function _getTokenValueInUSD(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(_tokenFeeds[token]);
        (, int256 price, , , ) = feed.latestRoundData();
        uint8 feedDec = feed.decimals();
        uint256 normalizedPrice = uint256(price) * (10 ** (18 - feedDec));
        uint256 usdValue = (amount * normalizedPrice) / 1e18;

        console.log("amount:", amount);
        console.log("normalizedPrice:", normalizedPrice);
        console.log("usdValue:", usdValue);
        console.log("price:", uint256(price));

        return usdValue;
    }

    // todo: might be wrong to have usedValue stipped
    function getTokenValueInUSD(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(_tokenFeeds[token]);
        (, int256 price, , , ) = feed.latestRoundData();
        uint8 feedDec = feed.decimals();
        uint256 normalizedPrice = uint256(price) * (10 ** (18 - feedDec));
        uint256 usdValue = (amount * normalizedPrice) / 1e18;

        console.log("amount:", amount);
        console.log("normalizedPrice:", normalizedPrice);
        console.log("usdValue:", usdValue);
        console.log("price:", uint256(price));

        return usdValue;
    }

    function selectWinner(uint256 index) internal view returns (address) {
        uint256 gid = gameId;
        require(
            randomResult[gid] != 0 && poolUSD[gid] > 0,
            "incorrect conditions"
        );

        uint256 winningPoint = randomResult[gid] % poolUSD[gid];
        UserWinningRange memory range = winningRanges[gid][index];

        require(
            winningPoint >= range.min && winningPoint < range.max,
            "incorrect winner idx"
        );
        return range.user;
    }

    function endGame(uint256 index) external onlyOwner {
        require(_canTriggerGame(), "Game ending conditions not met");
        _endGameInternal(index);
    }

    function _endGameInternal(uint256 index) internal {
        uint256 gid = gameId;
        require(gameState[gid] == GameState.RandomRequested, "invalid state");

        winner[gid] = selectWinner(index);

        _changeGameState(gid, GameState.Ended);
        emit GameEnded(gid, winner[gid]);
    }

    function _keeperEndAndStartGame(uint256 index) internal {
        _endGameInternal(index);
        _startGameInternal();
    }

    function claimWinningEth(uint256 gameId_, address token) public {
        require(gameState[gameId_] == GameState.Ended, "Game not ended");
        require(msg.sender == winner[gameId_], "Not the winner");

        uint256 tokenAmount = tokenBalances[gameId_][token];
        tokenBalances[gameId_][token] = 0;
        _swapTokensForETH(token, tokenAmount);
        emit WinnerClaimed(gameId_, msg.sender, token, tokenAmount);
    }

    function _swapTokensForETH(address token, uint256 amount) internal {
        IERC20(token).approve(address(swapRouter), amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: token,
                tokenOut: WETH,
                fee: 5000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: (amount * 95) / 100, // 5% slippage
                sqrtPriceLimitX96: 0
            });

        uint256 wethReceived = swapRouter.exactInputSingle(params);

        IWETH(WETH).withdraw(wethReceived);

        (bool success, ) = msg.sender.call{value: wethReceived}("");
        require(success, "Transfer failed");
    }

    function requestRandom() public onlyOwner {
        require(_canTriggerGame(), "Conditions not met");
        _requestRandomInternal();
    }

    function _changeGameState(uint256 gid, GameState newState) internal {
        GameState oldState = gameState[gid];
        gameState[gid] = newState;
        emit GameStateChanged(gid, oldState, newState);
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

    function setSubscription(uint subId) external onlyOwner {
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
            !_canTriggerGame()
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

    function _canTriggerGame() internal view returns (bool) {
        uint256 gid = gameId;
        uint256 userCount = users[gid].length;
        uint256 elapsed = block.timestamp - gameStart[gid];
        uint256 currentPool = poolUSD[gid];

        return
            userCount >= minUsersToTrigger ||
            elapsed >= maxGameDuration ||
            currentPool >= minPoolUSDToTrigger;
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

    function setAutomationEnabled(bool enabled) external onlyOwner {
        automationEnabled = enabled;
    }

    function getWinningRanges(
        uint256 gameId
    ) external view returns (UserWinningRange[] memory) {
        return winningRanges[gameId];
    }

    function getUsers(uint256 gameId) external view returns (address[] memory) {
        return users[gameId];
    }

    function canTriggerGameView(
        uint256 gid
    )
        external
        view
        returns (
            bool canTrigger,
            uint256 userCount,
            uint256 elapsed,
            uint256 currentPool
        )
    {
        userCount = users[gid].length;
        elapsed = block.timestamp - gameStart[gid];
        currentPool = poolUSD[gid];

        canTrigger =
            userCount >= minUsersToTrigger ||
            elapsed >= maxGameDuration ||
            currentPool >= minPoolUSDToTrigger;
    }

    function canRequestRandomView(
        uint256 gid
    )
        external
        view
        returns (
            bool canRequest,
            bool automation,
            GameState state,
            uint256 random,
            bool trigger
        )
    {
        automation = automationEnabled;
        state = gameState[gid];
        random = randomResult[gid];
        trigger = _canTriggerGame();

        canRequest =
            automation &&
            state == GameState.Active &&
            random == 0 &&
            trigger;
    }

    receive() external payable {}
}
