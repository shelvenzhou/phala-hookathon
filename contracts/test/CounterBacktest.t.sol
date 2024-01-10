// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";
import "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Counter} from "../src/Counter.sol";
import {CounterBacktest} from "../src/CounterBacktest.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

contract CounterBacktestTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    using stdJson for string;

    Counter counter;
    CounterBacktest backtest;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        // creates the pool manager, test tokens, and other utility routers
        Deployers.deployFreshManagerAndRouters();
        (currency0, currency1) = Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG
        );

        {
            (address hookAddress, bytes32 salt) =
                HookMiner.find(address(this), flags, type(Counter).creationCode, abi.encode(address(manager)));
            counter = new Counter{salt: salt}(IPoolManager(address(manager)));
            require(address(counter) == hookAddress, "CounterTest: hook address mismatch");
        }

        // Deploy the backtest hook
        {
            (address backtestHookAddress, bytes32 salt) =
                HookMiner.find(address(this), flags, type(CounterBacktest).creationCode, abi.encode(address(counter)));
            backtest = new CounterBacktest{salt: salt}(address(counter));
            require(address(backtest) == backtestHookAddress, "CounterTest: backtest hook address mismatch");
        }

        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(counter));
        poolId = poolKey.toId();
        initializeRouter.initialize(poolKey, Constants.SQRT_RATIO_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(-60, 60, 10 ether), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey, IPoolManager.ModifyLiquidityParams(-120, 120, 10 ether), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether),
            ZERO_BYTES
        );
    }

    struct HistoricalSwap {
        uint256 amountIn;
        uint256 amountOut;
        bytes32 tokenIn;
        bytes32 tokenOut;
    }

    function testBack() public {
        // read the historical swaps from json
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/contracts/test/res/mock.json");
        string memory json = vm.readFile(path);
        bytes memory swapDetails = json.parseRaw(".data.swaps");
        HistoricalSwap[] memory rawTxDetail = abi.decode(swapDetails, (HistoricalSwap[]));


        int256 totalOrigin0 = 0;
        int256 totalOrigin1 = 0;
        int256 totalReal0 = 0;
        int256 totalReal1 = 0;
        for (uint i = 0; i < rawTxDetail.length; i++) {
            bool zeroForOne = rawTxDetail[i].tokenIn < rawTxDetail[i].tokenOut;
            BalanceDelta swapDelta = swap(poolKey, int(rawTxDetail[i].amountIn), zeroForOne, ZERO_BYTES);

            if (zeroForOne) {
                totalOrigin0 += int(rawTxDetail[i].amountIn);
                totalOrigin1 -= int(rawTxDetail[i].amountOut);
            } else {
                totalOrigin0 -= int(rawTxDetail[i].amountOut);
                totalOrigin1 += int(rawTxDetail[i].amountIn);
            }

            totalReal0 += swapDelta.amount0();
            totalReal1 += swapDelta.amount1();

            console.log("%s:", i);

            console.log("token0");
            console.logInt(totalOrigin0);
            console.logInt(totalReal0);

            console.log("token1");
            console.logInt(totalOrigin1);
            console.logInt(totalReal1);

        }
    }

    // --- Util Helper --- //
    function swap(PoolKey memory key, int256 amountSpecified, bool zeroForOne, bytes memory hookData)
        internal
        returns (BalanceDelta swapDelta)
    {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1 // unlimited impact
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true, currencyAlreadySent: false});

        swapDelta = swapRouter.swap(key, params, testSettings, hookData);
    }
}
