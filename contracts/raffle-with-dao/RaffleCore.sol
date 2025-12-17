// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "./dao/RaffleGovernance.sol";

interface IWETH {
    function withdraw(uint256) external;
}

abstract contract RaffleCore is RaffleGovernance {
    ISwapRouter public swapRouter;
    IWETH public WETH;

    error NotSupportedToken();
    error ZeroAmount();
    error NoActiveRound();

    event Deposit(
        address indexed sender,
        address indexed token,
        uint256 tokenAmount,
        uint256 usdValue
    );
    event GameEnded(uint256 indexed gameId, address winner);
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

    constructor(address swapRouter_, address weth_) {
        swapRouter = ISwapRouter(swapRouter_);
        WETH = IWETH(weth_);
    }

    function addTokenFeed(address token, address feed) external onlyContractOwner {
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

    function startGame() public onlyContractOwner {
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

    // todo: add price stale, don't strip usd?
    function _getTokenValueInUSD(
        address token,
        uint256 amount
    ) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(_tokenFeeds[token]);
        (, int256 price, , , ) = feed.latestRoundData();
        uint8 feedDec = feed.decimals();
        uint256 normalizedPrice = uint256(price) * (10 ** (18 - feedDec));
        uint256 usdValue = (amount * normalizedPrice) / 1e18;

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

    function endGame(uint256 index) external onlyContractOwner {
        require(_canTriggerEndGame(), "Game ending conditions not met");
        _endGameInternal(index);
    }

    function _endGameInternal(uint256 index) internal {
        uint256 gid = gameId;
        require(gameState[gid] == GameState.RandomRequested, "invalid state");

        winner[gid] = selectWinner(index);

        _changeGameState(gid, GameState.Ended);
        emit GameEnded(gid, winner[gid]);
    }

    function _canTriggerEndGame() internal view returns (bool) {
        uint256 gid = gameId;
        uint256 userCount = users[gid].length;
        uint256 elapsed = block.timestamp - gameStart[gid];
        uint256 currentPool = poolUSD[gid];

        return
            userCount >= minUsersToTrigger ||
            elapsed >= maxGameDuration ||
            currentPool >= minPoolUSDToTrigger;
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
                tokenOut: address(WETH),
                fee: 5000,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: (amount * 95) / 100, // 5% slippage
                sqrtPriceLimitX96: 0
            });

        uint256 wethReceived = swapRouter.exactInputSingle(params);

        WETH.withdraw(wethReceived);

        (bool success, ) = msg.sender.call{value: wethReceived}("");
        require(success, "Transfer failed");
    }

    function _changeGameState(uint256 gid, GameState newState) internal {
        GameState oldState = gameState[gid];
        gameState[gid] = newState;
        emit GameStateChanged(gid, oldState, newState);
    }
}
