// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

interface IWETH { function withdraw(uint256) external; } // to unwrap weth to eth

contract Raffle is VRFConsumerBaseV2, AutomationCompatibleInterface, Ownable {

    uint32 public constant MAX_SUPPORTED_TOKENS = 100;
    uint32 public constant MAX_PARTICIPATED_USERS = 100;

    uint32 public supportedTokensCount;
    uint8 public MIN_PARTICIPATION_USD_DEPOSIT = 10; // can be omitted, just to minimize flooding with low amounts

    // keeper config (triggers)
    bool public automationEnabled;
    uint256 public minUsersToTrigger = 100;
    uint256 public maxGameDuration = 24 hours;
    uint256 public minPoolUSDToTrigger = 10_000 * 1e18; 

    uint256 gameId;
    mapping(uint256 => uint256) public poolUSD;
    mapping(uint256 => address[]) public users;
    mapping(uint256 => mapping(address => bool)) private _hasParticipated;
    mapping(uint256 => mapping(address => uint256)) public userPoolUSD;
    mapping(uint256 => mapping(address => uint256)) public tokenBalances;
    mapping(uint256 => address[]) public playedTokens;

    // for keepers
    mapping(uint256 => uint256) public gameStart;
    mapping(uint256 => bool) public randomRequestedForGame;

    mapping(address => address) private _tokenFeeds;

    VRFCoordinatorV2Mock public vrfCoordinator;

    uint64 public subscriptionId;
    bytes32 public keyHash;

    uint256 public lastRequestId;
    uint256 public randomResult;

    ISwapRouter public swapRouter;
    address public WETH;

    error NotSupportedToken();
    error ZeroAmount();
    error InvalidPrice();
    error PriceStale();
    error NoWinnerFound();
    error NoPoolValue();

    event Deposit(
        address indexed sender,
        address indexed token,
        uint256 tokenAmount,
        uint256 usdValue
    );
    event WinnerSelected(address winner, uint256 winnerPrize);
    event GameEnded(uint256 indexed gameId, address winner, uint256 totalETH);
    event AutomationTriggered(uint8 action, string reason, uint256 gameId);

    constructor(
        address vrfCoordinator_,
        bytes32 keyHash_,
        address swapRouter_
    ) VRFConsumerBaseV2(vrfCoordinator_) Ownable(msg.sender) {
        vrfCoordinator = VRFCoordinatorV2Mock(vrfCoordinator_);
        keyHash = keyHash_;
        swapRouter = ISwapRouter(swapRouter_);

        gameId = 0;
        gameStart[gameId] = block.timestamp;
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
                users[gameId].length < MAX_PARTICIPATED_USERS,
                "User limit per round reached"
            );
            users[gameId].push(msg.sender);
            _hasParticipated[gameId][msg.sender] = true;
        }

        userPoolUSD[gameId][msg.sender] += usdValue;
        poolUSD[gameId] += usdValue;

        emit Deposit(msg.sender, token, amount, usdValue);
    }

    function _getTokenValueInUSD(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(_tokenFeeds[token]);

        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();

        if (price <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > 1 hours) revert PriceStale(); // todo: can vary

        uint8 feedDec = feed.decimals();
        uint256 normalizedPrice = uint256(price) * (10 ** (18 - feedDec));

        return (amount * normalizedPrice) / 1e18;
    }

    // must have requestRandom called previously (otherwise predictable random)
    function findWinner() public view returns (address) {
        if (poolUSD[gameId] == 0) revert NoPoolValue();

        uint256 winnningPoint = randomResult % poolUSD[gameId];

        uint256 sum = 0;
        address[] memory gameUsers = users[gameId];
        for (uint32 i = 0; i < gameUsers.length; ++i) {
            address user = gameUsers[i];
            sum += userPoolUSD[gameId][user];

            if (winnningPoint < sum) return user;
        }

        revert NoWinnerFound();
    }

    function endGame() external onlyOwner {
        _endGameInternal();
    }

    function _endGameInternal() internal { // todo: add nonreentrant
        address winner = findWinner();
        uint256 currGameId = gameId;

        uint256 totalETH = 0;
        address[] memory tokens = playedTokens[currGameId];

        for (uint8 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 balance = tokenBalances[currGameId][token];

            uint256 ethReceived = _swapTokensForETH(token, balance);
            totalETH += ethReceived;
        }

        gameId++;
        gameStart[gameId] = block.timestamp;

        IWETH(WETH).withdraw(totalETH);
        (bool success, ) = payable(winner).call{value: totalETH}("");
        require(success, "Winner transfer failed");

        emit WinnerSelected(winner, totalETH);
        emit GameEnded(currGameId, winner, totalETH);
    }

    function _swapTokensForETH(
        address token,
        uint256 amount
    ) internal returns (uint256) {
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

        uint256 ethReceived = swapRouter.exactInputSingle(params);
        require(ethReceived > 0, "Swap failed");
        return ethReceived;
    }

    function requestRandom() public onlyOwner {
        _requestRandomInternal();
    }

    function _requestRandomInternal() internal {
        if (randomRequestedForGame[gameId]) return;

        lastRequestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            2,
            100000,
            1
        );

        randomRequestedForGame[gameId] = true;
        emit AutomationTriggered(1, "random_requested", gameId);
    }

    function setSubscription(uint64 subId) external onlyOwner {
        subscriptionId = subId;
    }

    // callback used by vpf coordinator
    function fulfillRandomWords(
        uint256,
        uint256[] memory randomWords
    ) internal virtual override {
        randomResult = randomWords[0]; // todo: add requestId to fix race condition
    }

    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        if (!automationEnabled) return (false, bytes(""));

        uint256 gid = gameId;
        uint256 currentPool = poolUSD[gid];
        uint256 userCount = users[gid].length;
        uint256 elapsed = block.timestamp - gameStart[gid];

        // if randomRequested not invoked yet and any trigger meets -> request randomness
        if (!randomRequestedForGame[gid]) {
            bool userThreshold = userCount >= minUsersToTrigger;
            bool timeThreshold = elapsed >= maxGameDuration;
            bool poolThreshold = currentPool >= minPoolUSDToTrigger;
            if (userThreshold) {
                return (true, abi.encode(uint8(1), "users_threshold"));
            }
            if (timeThreshold) {
                return (true, abi.encode(uint8(1), "time_threshold"));
            }
            if (poolThreshold) {
                return (true, abi.encode(uint8(1), "pool_threshold"));
            }
            return (false, bytes(""));
        }

        // if randomness was requested and VRF produced a randomResult -> end game
        if (randomRequestedForGame[gid] && randomResult != 0) {
            return (true, abi.encode(uint8(2), "random_ready"));
        }

        return (false, bytes(""));
    }

    function performUpkeep(bytes calldata performData) external override {
        require(automationEnabled, "Automation disabled");

        (uint8 action, bytes memory reasonBytes) = abi.decode(performData, (uint8, bytes));
        if (action == 1) {
            _requestRandomInternal();
            emit AutomationTriggered(1, string(reasonBytes), gameId);
        } else if (action == 2) {
            _endGameInternal();
            emit AutomationTriggered(2, string(reasonBytes), gameId);
        } else {
            revert("Unknown upkeep action");
        }
    }

    function setAutomationEnabled(bool enabled) external onlyOwner {
        automationEnabled = enabled;
    }

    function setAutomationConfig(
        uint256 minUsers,
        uint256 maxDuration,
        uint256 minPoolUSD
    ) external onlyOwner {
        minUsersToTrigger = minUsers;
        maxGameDuration = maxDuration;
        minPoolUSDToTrigger = minPoolUSD;
    }

    receive() external payable {}
}
