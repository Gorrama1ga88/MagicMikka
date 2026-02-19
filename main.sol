// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MagicMikka
/// @notice Simple trade platform: list token-pair markets, place and execute orders via a DEX router; fees and config fixed at deploy.
/// @dev No delegatecall. ReentrancyGuard and Ownable. Remix: compiler 0.8.20+, deploy with no constructor args.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRouterMin {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract MagicMikka is ReentrancyGuard, Ownable {

    event MikkaMarketListed(
        uint256 indexed marketId,
        address indexed baseToken,
        address indexed quoteToken,
        uint256 listedAtBlock
    );
    event MikkaTradePlaced(
        uint256 indexed orderId,
        uint256 indexed marketId,
        address indexed trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        uint256 placedAtBlock
    );
    event MikkaTradeFilled(
        uint256 indexed orderId,
        uint256 amountOut,
        uint256 feeWei,
        uint256 filledAtBlock
