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
        uint256 marketId;
        address trader;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 amountOutMin;
        uint256 deadline;
        bool filled;
        bool cancelled;
        uint256 placedAtBlock;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => Order) public orders;
    mapping(uint256 => uint256[]) private _marketOrderIds;
    mapping(bytes32 => bool) private _marketKeyExists;

    modifier onlyGuard() {
        if (msg.sender != platformGuard) revert MMK_NotPlatformGuard();
        _;
    }

    modifier whenNotPaused() {
        if (platformPaused) revert MMK_Paused();
        _;
    }

    constructor() {
        feeCollector = address(0x1F2a3B4c5D6e7F8a9b0C1d2E3f4A5b6C7d8E9f0A);
        weth = address(0x2A3b4C5d6E7f8A9b0c1D2e3F4a5B6c7D8e9F0a1);
        router = address(0x3B4c5D6e7F8a9B0c1d2E3f4A5b6C7d8E9f0A1b2);
        platformGuard = address(0x4C5d6E7f8A9b0C1d2e3F4a5B6c7D8e9F0a1B2c3);
        genesisBlock = block.number;
        platformNonce = keccak256(abi.encodePacked("MagicMikka_", block.chainid, block.timestamp, address(this)));
    }

    function setPlatformPaused(bool paused) external onlyOwner {
        platformPaused = paused;
        emit MikkaPlatformPaused(paused);
    }

    function setRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert MMK_ZeroAddress();
        address prev = router;
        router = newRouter;
        emit MikkaRouterUpdated(prev, newRouter);
    }

    function setPlatformGuard(address newGuard) external onlyOwner {
        if (newGuard == address(0)) revert MMK_ZeroAddress();
        address prev = platformGuard;
        platformGuard = newGuard;
        emit MikkaPlatformGuardUpdated(prev, newGuard);
    }

    function _marketKey(address base, address quote) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(base, quote));
    }

    function listMarket(address baseToken, address quoteToken) external onlyGuard whenNotPaused returns (uint256 marketId) {
        if (baseToken == address(0) || quoteToken == address(0)) revert MMK_ZeroAddress();
        if (baseToken == quoteToken) revert MMK_InvalidMarket();
        bytes32 key = _marketKey(baseToken, quoteToken);
        if (_marketKeyExists[key]) revert MMK_MarketExists();
        if (marketCounter >= MIKKA_MAX_MARKETS) revert MMK_PathLength();

        marketCounter++;
        marketId = marketCounter;
        _marketKeyExists[key] = true;
        markets[marketId] = Market({
            baseToken: baseToken,
            quoteToken: quoteToken,
            listedAtBlock: block.number,
            active: true
        });
        emit MikkaMarketListed(marketId, baseToken, quoteToken, block.number);
        return marketId;
    }

    function placeOrder(
        uint256 marketId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external whenNotPaused returns (uint256 orderId) {
        if (amountIn == 0) revert MMK_ZeroAmount();
        if (tokenIn == address(0) || tokenOut == address(0)) revert MMK_ZeroAddress();
        if (deadline <= block.timestamp) revert MMK_OrderExpired();

        Market storage m = markets[marketId];
        if (m.listedAtBlock == 0 || !m.active) revert MMK_MarketNotFound();
        if ((tokenIn != m.baseToken || tokenOut != m.quoteToken) && (tokenIn != m.quoteToken || tokenOut != m.baseToken)) revert MMK_InvalidMarket();

        uint256[] memory orderIds = _marketOrderIds[marketId];
        if (orderIds.length >= MIKKA_MAX_ORDERS_PER_MARKET) revert MMK_PathLength();

        orderCounter++;
        orderId = orderCounter;
        orders[orderId] = Order({
            marketId: marketId,
            trader: msg.sender,
            tokenIn: tokenIn,
