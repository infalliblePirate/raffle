// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockV3Aggregator {
    int256 public price;
    uint8 public decimals;
    uint256 public updatedAt;
    
    constructor(uint8 _decimals, int256 _initialPrice) {
        decimals = _decimals;
        price = _initialPrice;
        updatedAt = block.timestamp;
    }
    
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt_,
        uint80 answeredInRound
    ) {
        return (1, price, block.timestamp, updatedAt, 1);
    }
    
    function updatePrice(int256 newPrice) external {
        price = newPrice;
        updatedAt = block.timestamp;
    }
}