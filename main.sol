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
    );
    event MikkaTradeCancelled(uint256 indexed orderId, uint256 atBlock);
    event MikkaFeesCollected(address indexed token, address indexed to, uint256 amountWei);
    event MikkaPlatformPaused(bool paused);
    event MikkaRouterUpdated(address indexed previousRouter, address indexed newRouter);
    event MikkaPlatformGuardUpdated(address indexed previousGuard, address indexed newGuard);

    error MMK_ZeroAmount();
    error MMK_ZeroAddress();
    error MMK_NotPlatformGuard();
    error MMK_TransferFailed();
    error MMK_MarketExists();
    error MMK_MarketNotFound();
    error MMK_OrderNotFound();
    error MMK_OrderExpired();
    error MMK_OrderFilled();
    error MMK_OrderCancelled();
    error MMK_Slippage();
    error MMK_Paused();
    error MMK_PathLength();
    error MMK_InsufficientBalance();
    error MMK_RouterFailed();
    error MMK_InvalidMarket();

    uint256 public constant MIKKA_BPS_DENOM = 10000;
    uint256 public constant MIKKA_FEE_BPS = 15;
    uint256 public constant MIKKA_MAX_SLIPPAGE_BPS = 100;
    uint256 public constant MIKKA_MIN_PATH_LEN = 2;
    uint256 public constant MIKKA_MAX_PATH_LEN = 5;
    uint256 public constant MIKKA_MAX_MARKETS = 128;
    uint256 public constant MIKKA_MAX_ORDERS_PER_MARKET = 256;
    bytes32 public constant MIKKA_PLATFORM_SALT = bytes32(uint256(0x2e4f6a8b0c2d4e6f8a0b2c4d6e8f0a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a));

    address public immutable feeCollector;
    address public immutable weth;
    uint256 public immutable genesisBlock;
    bytes32 public immutable platformNonce;

    address public router;
    address public platformGuard;
    bool public platformPaused;
    uint256 public marketCounter;
    uint256 public orderCounter;

    struct Market {
        address baseToken;
        address quoteToken;
        uint256 listedAtBlock;
        bool active;
    }

    struct Order {
