// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract RaffleStorage {
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

    uint32 public constant MAX_SUPPORTED_TOKENS = 100;
    uint32 public supportedTokensCount;
    uint8 public MIN_PARTICIPATION_USD_DEPOSIT = 0;

    uint8 public platformFeePercent = 0;
    uint8 public founderFeePercent = 0;
    uint8 public winnerFeePercent = 100;
    address public platformAddress;
    address public founderAddress;
    address public governance;

    uint256 public gameId;
    mapping(uint256 => GameState) public gameState;
    mapping(uint256 => uint256) public poolUSD;
    mapping(uint256 => address[]) public users;
    mapping(uint256 => mapping(address => bool)) internal _hasParticipated;
    mapping(uint256 => mapping(address => uint256)) public tokenBalances;
    mapping(uint256 => address[]) public playedTokens;
    mapping(uint256 => address) public winner;
    mapping(uint256 => UserWinningRange[]) public winningRanges;
    mapping(uint256 => uint256) public gameStart;
    mapping(uint256 => uint256) public randomResult;

    mapping(uint256 => uint256) public gameIdForRequest;
    uint256 public lastRequestId;

    mapping(address => address) internal _tokenFeeds;

    uint256 public subscriptionId;

    uint32 public constant MAX_PARTICIPATED_USERS = 2;
    uint256 public minUsersToTrigger = MAX_PARTICIPATED_USERS;
    uint256 public maxGameDuration = 24 hours;
    uint256 public minPoolUSDToTrigger = 10_000 * 1e18;
    bool public automationEnabled;

    bytes32 public keyHash =
        0x3f631d5ec60a0ce8203ca649b3f89f4df96dd01bd96763dbb252c5a3c5590f8a;
    uint32 public callbackGasLimit = 60_000;

    address public contractOwner;

    error NotGovernance();
    error ZeroAddress();
    error NotContractOwner();

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier onlyContractOwner() {
        if (msg.sender != contractOwner) revert NotContractOwner();
        _;
    }

    constructor(
        address _initOwner,
        address gov_,
        address plat_,
        address found_
    ) {
        contractOwner = _initOwner;
        governance = gov_;
        platformAddress = plat_;
        founderAddress = found_;
    }
}
