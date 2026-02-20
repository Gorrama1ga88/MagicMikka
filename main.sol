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
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOutMin: amountOutMin,
            deadline: deadline,
            filled: false,
            cancelled: false,
            placedAtBlock: block.number
        });
        _marketOrderIds[marketId].push(orderId);
        _incrementTraderOrderCount(msg.sender);

        emit MikkaTradePlaced(orderId, marketId, msg.sender, tokenIn, tokenOut, amountIn, amountOutMin, deadline, block.number);
        return orderId;
    }

    function executeOrder(uint256 orderId) external nonReentrant whenNotPaused returns (uint256 amountOut, uint256 feeWei) {
        Order storage o = orders[orderId];
        if (o.placedAtBlock == 0) revert MMK_OrderNotFound();
        if (o.filled) revert MMK_OrderFilled();
        if (o.cancelled) revert MMK_OrderCancelled();
        if (block.timestamp > o.deadline) revert MMK_OrderExpired();

        address[] memory path = new address[](2);
        path[0] = o.tokenIn;
        path[1] = o.tokenOut;

        feeWei = (o.amountIn * MIKKA_FEE_BPS) / MIKKA_BPS_DENOM;
        uint256 amountInAfterFee = o.amountIn - feeWei;

        IERC20Min(o.tokenIn).transferFrom(o.trader, address(this), o.amountIn);
        if (feeWei > 0) {
            bool ok = IERC20Min(o.tokenIn).transfer(feeCollector, feeWei);
            if (!ok) revert MMK_TransferFailed();
        }

        IERC20Min(o.tokenIn).approve(router, amountInAfterFee);
        uint256 balanceBefore = IERC20Min(o.tokenOut).balanceOf(o.trader);

        try IRouterMin(router).swapExactTokensForTokens(
            amountInAfterFee,
            o.amountOutMin,
            path,
            o.trader,
            o.deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
        } catch {
            IERC20Min(o.tokenIn).approve(router, 0);
            bool refund = IERC20Min(o.tokenIn).transfer(o.trader, o.amountIn);
            if (!refund) revert MMK_TransferFailed();
            revert MMK_RouterFailed();
        }

        IERC20Min(o.tokenIn).approve(router, 0);
        uint256 balanceAfter = IERC20Min(o.tokenOut).balanceOf(o.trader);
        if (balanceAfter <= balanceBefore) revert MMK_TransferFailed();
        amountOut = balanceAfter - balanceBefore;

        o.filled = true;
        emit MikkaTradeFilled(orderId, amountOut, feeWei, block.number);
        return (amountOut, feeWei);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.placedAtBlock == 0) revert MMK_OrderNotFound();
        if (o.filled) revert MMK_OrderFilled();
        if (o.trader != msg.sender && msg.sender != platformGuard) revert MMK_NotPlatformGuard();
        o.cancelled = true;
        emit MikkaTradeCancelled(orderId, block.number);
    }

    function quoteOut(uint256 marketId, address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOutEst) {
        Market storage m = markets[marketId];
        if (m.listedAtBlock == 0) return 0;
        if (amountIn == 0 || tokenIn == address(0) || tokenOut == address(0)) return 0;
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        (bool success, bytes memory data) = router.staticcall(
            abi.encodeWithSignature("getAmountsOut(uint256,address[])", amountIn, path)
        );
        if (!success || data.length < 32) return 0;
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        if (amounts.length < 2) return 0;
        return amounts[amounts.length - 1];
    }

    function getMarket(uint256 marketId) external view returns (
        address baseToken,
        address quoteToken,
        uint256 listedAtBlock,
        bool active
    ) {
        Market storage m = markets[marketId];
        if (m.listedAtBlock == 0) revert MMK_MarketNotFound();
        return (m.baseToken, m.quoteToken, m.listedAtBlock, m.active);
    }

    function getOrder(uint256 orderId) external view returns (
        uint256 marketId,
        address trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline,
        bool filled,
        bool cancelled,
        uint256 placedAtBlock
    ) {
        Order storage o = orders[orderId];
        if (o.placedAtBlock == 0) revert MMK_OrderNotFound();
        return (
            o.marketId,
            o.trader,
            o.tokenIn,
            o.tokenOut,
            o.amountIn,
            o.amountOutMin,
            o.deadline,
            o.filled,
            o.cancelled,
            o.placedAtBlock
        );
    }

    function getMarketOrderIds(uint256 marketId) external view returns (uint256[] memory) {
        return _marketOrderIds[marketId];
    }

    function getMarketOrderCount(uint256 marketId) external view returns (uint256) {
        return _marketOrderIds[marketId].length;
    }

    function getOrderCount() external view returns (uint256) {
        return orderCounter;
    }

    function getMarketCount() external view returns (uint256) {
        return marketCounter;
    }

    function setMarketActive(uint256 marketId, bool active) external onlyOwner {
        Market storage m = markets[marketId];
        if (m.listedAtBlock == 0) revert MMK_MarketNotFound();
        m.active = active;
    }

    function withdrawStuckToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert MMK_ZeroAddress();
        bool ok = IERC20Min(token).transfer(to, amount);
        if (!ok) revert MMK_TransferFailed();
    }

    // -------------------------------------------------------------------------
    // Batch view helpers (no state change)
    // -------------------------------------------------------------------------

    function getMarketsBatch(uint256 fromId, uint256 count) external view returns (
        uint256[] memory ids,
        address[] memory baseTokens,
        address[] memory quoteTokens,
        uint256[] memory listedAtBlocks,
        bool[] memory actives
    ) {
        uint256 maxId = marketCounter;
        if (fromId == 0 || fromId > maxId) {
            ids = new uint256[](0);
            baseTokens = new address[](0);
            quoteTokens = new address[](0);
            listedAtBlocks = new uint256[](0);
            actives = new bool[](0);
            return (ids, baseTokens, quoteTokens, listedAtBlocks, actives);
        }
        uint256 len = count;
        if (fromId + len > maxId + 1) len = maxId - fromId + 1;
        ids = new uint256[](len);
        baseTokens = new address[](len);
        quoteTokens = new address[](len);
        listedAtBlocks = new uint256[](len);
        actives = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = fromId + i;
            Market storage m = markets[id];
            ids[i] = id;
            baseTokens[i] = m.baseToken;
            quoteTokens[i] = m.quoteToken;
            listedAtBlocks[i] = m.listedAtBlock;
            actives[i] = m.active;
        }
        return (ids, baseTokens, quoteTokens, listedAtBlocks, actives);
    }

    function getOrdersBatch(uint256 fromId, uint256 count) external view returns (
        uint256[] memory ids,
        uint256[] memory marketIds,
        address[] memory traders,
        address[] memory tokensIn,
        address[] memory tokensOut,
        uint256[] memory amountsIn,
        uint256[] memory amountsOutMin,
        uint256[] memory deadlines,
        bool[] memory filleds,
        bool[] memory cancelleds,
        uint256[] memory placedAtBlocks
    ) {
        uint256 maxId = orderCounter;
        if (fromId == 0 || fromId > maxId) {
            ids = new uint256[](0);
            marketIds = new uint256[](0);
            traders = new address[](0);
            tokensIn = new address[](0);
            tokensOut = new address[](0);
            amountsIn = new uint256[](0);
            amountsOutMin = new uint256[](0);
            deadlines = new uint256[](0);
            filleds = new bool[](0);
            cancelleds = new bool[](0);
            placedAtBlocks = new uint256[](0);
            return (ids, marketIds, traders, tokensIn, tokensOut, amountsIn, amountsOutMin, deadlines, filleds, cancelleds, placedAtBlocks);
        }
        uint256 len = count;
        if (fromId + len > maxId + 1) len = maxId - fromId + 1;
        ids = new uint256[](len);
        marketIds = new uint256[](len);
        traders = new address[](len);
        tokensIn = new address[](len);
        tokensOut = new address[](len);
        amountsIn = new uint256[](len);
        amountsOutMin = new uint256[](len);
        deadlines = new uint256[](len);
        filleds = new bool[](len);
        cancelleds = new bool[](len);
        placedAtBlocks = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 id = fromId + i;
            Order storage o = orders[id];
            ids[i] = id;
            marketIds[i] = o.marketId;
            traders[i] = o.trader;
            tokensIn[i] = o.tokenIn;
            tokensOut[i] = o.tokenOut;
            amountsIn[i] = o.amountIn;
            amountsOutMin[i] = o.amountOutMin;
            deadlines[i] = o.deadline;
            filleds[i] = o.filled;
            cancelleds[i] = o.cancelled;
            placedAtBlocks[i] = o.placedAtBlock;
        }
        return (ids, marketIds, traders, tokensIn, tokensOut, amountsIn, amountsOutMin, deadlines, filleds, cancelleds, placedAtBlocks);
    }

    function getOpenOrderIdsForMarket(uint256 marketId) external view returns (uint256[] memory) {
        uint256[] memory allIds = _marketOrderIds[marketId];
        uint256 openCount = 0;
        for (uint256 i = 0; i < allIds.length; i++) {
            Order storage o = orders[allIds[i]];
            if (!o.filled && !o.cancelled && block.timestamp <= o.deadline) openCount++;
        }
        uint256[] memory openIds = new uint256[](openCount);
        uint256 j = 0;
        for (uint256 i = 0; i < allIds.length; i++) {
            Order storage o = orders[allIds[i]];
            if (!o.filled && !o.cancelled && block.timestamp <= o.deadline) {
                openIds[j] = allIds[i];
                j++;
            }
        }
        return openIds;
    }

    function getOpenOrderCountForMarket(uint256 marketId) external view returns (uint256) {
        uint256[] memory allIds = _marketOrderIds[marketId];
        uint256 count = 0;
        for (uint256 i = 0; i < allIds.length; i++) {
            Order storage o = orders[allIds[i]];
            if (!o.filled && !o.cancelled && block.timestamp <= o.deadline) count++;
        }
        return count;
    }

    function marketExists(bytes32 key) external view returns (bool) {
        return _marketKeyExists[key];
    }

    function marketIdByPair(address baseToken, address quoteToken) external view returns (uint256) {
        bytes32 key = _marketKey(baseToken, quoteToken);
        if (!_marketKeyExists[key]) return 0;
        for (uint256 i = 1; i <= marketCounter; i++) {
            Market storage m = markets[i];
            if (m.baseToken == baseToken && m.quoteToken == quoteToken) return i;
        }
        return 0;
    }

    function isOrderExecutable(uint256 orderId) external view returns (bool) {
        Order storage o = orders[orderId];
        if (o.placedAtBlock == 0 || o.filled || o.cancelled) return false;
        if (block.timestamp > o.deadline) return false;
        Market storage m = markets[o.marketId];
        return m.listedAtBlock != 0 && m.active;
    }

    function minAmountOutWithSlippage(uint256 amountOutEst, uint256 slippageBps) public pure returns (uint256) {
        if (slippageBps > MIKKA_BPS_DENOM) slippageBps = MIKKA_BPS_DENOM;
        return (amountOutEst * (MIKKA_BPS_DENOM - slippageBps)) / MIKKA_BPS_DENOM;
    }

    function feeForAmount(uint256 amountIn) public pure returns (uint256) {
        return (amountIn * MIKKA_FEE_BPS) / MIKKA_BPS_DENOM;
    }

    function amountInAfterFee(uint256 amountIn) public pure returns (uint256) {
        return amountIn - feeForAmount(amountIn);
    }

    // -------------------------------------------------------------------------
    // Direct swap (no order): user sends tokenIn, receives tokenOut via router
    // -------------------------------------------------------------------------

    event MikkaDirectSwap(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeWei,
        uint256 atBlock
    );

    function executeSwapDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 amountOut, uint256 feeWei) {
        if (amountIn == 0) revert MMK_ZeroAmount();
        if (tokenIn == address(0) || tokenOut == address(0)) revert MMK_ZeroAddress();

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        feeWei = feeForAmount(amountIn);
        uint256 amountInAfterFee = amountIn - feeWei;

        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (feeWei > 0) {
            bool ok = IERC20Min(tokenIn).transfer(feeCollector, feeWei);
            if (!ok) revert MMK_TransferFailed();
        }

        IERC20Min(tokenIn).approve(router, amountInAfterFee);
        uint256 balanceBefore = IERC20Min(tokenOut).balanceOf(msg.sender);

        try IRouterMin(router).swapExactTokensForTokens(
            amountInAfterFee,
            amountOutMin,
            path,
            msg.sender,
            deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
        } catch {
            IERC20Min(tokenIn).approve(router, 0);
            bool refund = IERC20Min(tokenIn).transfer(msg.sender, amountIn);
            if (!refund) revert MMK_TransferFailed();
            revert MMK_RouterFailed();
        }

        IERC20Min(tokenIn).approve(router, 0);
        uint256 balanceAfter = IERC20Min(tokenOut).balanceOf(msg.sender);
        if (balanceAfter <= balanceBefore) revert MMK_TransferFailed();
        amountOut = balanceAfter - balanceBefore;

        emit MikkaDirectSwap(msg.sender, tokenIn, tokenOut, amountIn, amountOut, feeWei, block.number);
        return (amountOut, feeWei);
    }

    // -------------------------------------------------------------------------
    // Quote and stats views (read-only, no state change)
    // -------------------------------------------------------------------------

    function quoteDirect(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOutEst) {
        if (amountIn == 0 || tokenIn == address(0) || tokenOut == address(0)) return 0;
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        (bool success, bytes memory data) = router.staticcall(
            abi.encodeWithSignature("getAmountsOut(uint256,address[])", amountIn, path)
        );
        if (!success || data.length < 32) return 0;
        uint256[] memory amounts = abi.decode(data, (uint256[]));
        if (amounts.length < 2) return 0;
        amountOutEst = amounts[amounts.length - 1];
    }

    function quoteDirectAfterFee(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOutEst) {
        uint256 afterFee = amountInAfterFee(amountIn);
        return quoteDirect(tokenIn, tokenOut, afterFee);
    }

    function getPlatformConfig() external view returns (
        address feeCollector_,
        address weth_,
        address router_,
        address platformGuard_,
        uint256 genesisBlock_,
        bool platformPaused_,
        uint256 marketCount_,
        uint256 orderCount_
    ) {
        return (
            feeCollector,
            weth,
            router,
            platformGuard,
            genesisBlock,
            platformPaused,
            marketCounter,
            orderCounter
        );
    }

    function getOrderSummary(uint256 orderId) external view returns (
        uint256 marketId_,
        address trader_,
        uint256 amountIn_,
        uint256 amountOutMin_,
        uint256 deadline_,
        bool filled_,
        bool cancelled_
    ) {
        Order storage o = orders[orderId];
        if (o.placedAtBlock == 0) revert MMK_OrderNotFound();
        return (
            o.marketId,
            o.trader,
            o.amountIn,
            o.amountOutMin,
            o.deadline,
            o.filled,
            o.cancelled
        );
    }

    function getMarketSummary(uint256 marketId) external view returns (
        address baseToken_,
        address quoteToken_,
        uint256 orderCount_,
        bool active_
    ) {
        Market storage m = markets[marketId];
        if (m.listedAtBlock == 0) revert MMK_MarketNotFound();
        return (
            m.baseToken,
            m.quoteToken,
            _marketOrderIds[marketId].length,
            m.active
        );
    }

    /// Returns order IDs for a market in range [offset, offset+limit), only open orders if openOnly is true
    function getMarketOrderIdsPaginated(
        uint256 marketId,
        uint256 offset,
        uint256 limit,
        bool openOnly
    ) external view returns (uint256[] memory orderIds) {
        uint256[] memory allIds = _marketOrderIds[marketId];
        uint256 total = allIds.length;
        if (offset >= total) {
            orderIds = new uint256[](0);
            return orderIds;
        }
        uint256 maxLen = limit;
        if (offset + maxLen > total) maxLen = total - offset;

        if (!openOnly) {
            orderIds = new uint256[](maxLen);
            for (uint256 i = 0; i < maxLen; i++) {
                orderIds[i] = allIds[offset + i];
            }
            return orderIds;
        }

        uint256 openCount = 0;
        for (uint256 i = offset; i < offset + maxLen && i < total; i++) {
            Order storage o = orders[allIds[i]];
            if (!o.filled && !o.cancelled && block.timestamp <= o.deadline) openCount++;
        }
        orderIds = new uint256[](openCount);
        uint256 j = 0;
        for (uint256 i = offset; i < offset + maxLen && i < total; i++) {
            Order storage o = orders[allIds[i]];
            if (!o.filled && !o.cancelled && block.timestamp <= o.deadline) {
                orderIds[j] = allIds[i];
                j++;
            }
        }
        return orderIds;
    }

    /// Check if a market is listed and active for base/quote pair
    function isMarketListed(address baseToken, address quoteToken) external view returns (bool) {
        bytes32 key = _marketKey(baseToken, quoteToken);
        if (!_marketKeyExists[key]) return false;
        for (uint256 i = 1; i <= marketCounter; i++) {
            Market storage m = markets[i];
            if (m.baseToken == baseToken && m.quoteToken == quoteToken && m.active) return true;
        }
        return false;
    }

    /// Returns the number of filled orders globally
    function getFilledOrderCount() external view returns (uint256 count) {
        for (uint256 i = 1; i <= orderCounter; i++) {
            if (orders[i].filled) count++;
