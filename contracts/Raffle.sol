// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract Raffle is Ownable {

    mapping(address => address) private _tokenFeeds;
    address[] public playedTokens;
    mapping(address => uint256) public tokenBalances;
    mapping(address => mapping(address => uint256)) public userDepositedBalances;

    error NotSupportedToken();
    error ZeroAmount();

    event Deposit(address indexed sender, address indexed token, uint256 amount);

    constructor(address founder) Ownable(msg.sender) {}

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

        if (tokenBalances[token] == 0) {
            playedTokens.push(token);
        }
        tokenBalances[token] += amount;

        userDepositedBalances[msg.sender][token] += amount;
        emit Deposit(msg.sender, token, amount);
    }

    function selectWinner() external {}

    function endGame() external {}
}
