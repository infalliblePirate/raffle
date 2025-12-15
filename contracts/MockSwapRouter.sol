// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./MockWETH.sol";
contract MockSwapRouter {
    address public WETH;
    
    constructor(address _weth) {
        WETH = _weth;
    }
    
    function exactInputSingle(
        ISwapRouter.ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {
        // Transfer tokens from sender
        IERC20(params.tokenIn).transferFrom(
            msg.sender,
            address(this),
            params.amountIn
        );
        
        // Mint WETH to sender (simulating swap)
        MockWETH(payable(WETH)).mint(msg.sender, params.amountIn);
        
        return params.amountIn;
    }
}