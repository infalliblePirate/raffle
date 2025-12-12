// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2Mock.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract Raffle is Ownable, VRFConsumerBaseV2 {

    struct GameState {
        uint256 poolUSD;
        bool isEnded;
        uint256 startTime;
    }
    GameState public gameState;

    uint256 gameId;
    mapping(uint256 => address[]) users;
    mapping(uint256 => mapping(address => bool)) private _hasParticipated; // gameId -> user -> bool
    mapping(uint256 => mapping(address => uint256)) public userPoolUSD;

    mapping(address => address) private _tokenFeeds;

    VRFCoordinatorV2Mock public vrfCoordinator;

    uint64 public subscriptionId;
    bytes32 public keyHash;

    uint256 public lastRequestId;
    uint256 public randomResult;

    error NotSupportedToken();
    error ZeroAmount();
    error InvalidPrice();
    error PriceStale();
    error NoWinnerFound();
    error NoPoolValue();

    event Deposit(
        address indexed sender,
        address indexed token,
        uint256 amount
    );

    constructor(
        address vrfCoordinator_,
        bytes32 keyHash
    ) VRFConsumerBaseV2(vrfCoordinator_) Ownable(msg.sender) {
        vrfCoordinator = VRFCoordinatorV2Mock(vrfCoordinator_);
    }

    function addTokenFeed(address token, address feed) external onlyOwner {
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

        uint256 usdValue = _getTokenValueInUSD(token, amount);

        if (!_hasParticipated[gameId][msg.sender]) {
            users[gameId].push(msg.sender);
            _hasParticipated[gameId][msg.sender] = true;
        }

        userPoolUSD[gameId][msg.sender] += usdValue;
        gameState.poolUSD += usdValue;

        emit Deposit(msg.sender, token, amount);
    }

    function _getTokenValueInUSD(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface feed = AggregatorV3Interface(_tokenFeeds[token]);

        (, int256 price, , uint256 updatedAt, ) = feed.latestRoundData();

        if (price <= 0) revert InvalidPrice();
        if (block.timestamp - updatedAt > 1 hours) revert PriceStale();

        uint8 feedDec = feed.decimals();
        uint256 normalizedPrice = uint256(price) * (10 ** (18 - feedDec));

        return (amount * normalizedPrice) / 1e18;
    }

    function findWinner() public returns (address) {
        if (gameState.poolUSD == 0) revert NoPoolValue();

        requestRandom();
        uint256 winnningPoint = randomResult % gameState.poolUSD;

        uint256 sum = 0;

        for (uint256 i = 0; i < users[gameId].length; ++i) { // todo: change it to have max users
            address user = users[gameId][i];
            sum += userPoolUSD[gameId][user];

            if (winnningPoint < sum) return user;
        }

        revert NoWinnerFound();
    }

    function requestRandom() public onlyOwner {
        lastRequestId = vrfCoordinator.requestRandomWords(
            keyHash,
            subscriptionId,
            2,
            100000,
            1
        );
    }

    function endGame() external {}

    function setSubscription(uint64 subId) external {
        subscriptionId = subId;
    }

    // callback used by vpf coordinator
    function fulfillRandomWords(
        uint256,
        uint256[] memory randomWords
    ) internal virtual override {
        randomResult = randomWords[0];
    }
}
