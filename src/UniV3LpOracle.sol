// SPDX-License-Identifier: AGPL-v3
pragma solidity ^0.8.4;

import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import {Denominations} from "./external/Denominations.sol";
import {FeedRegistryInterface, AggregatorV2V3Interface} from "./external/FeedRegistryInterface.sol";

/// @title Uniswap V3 liquidity position price oracle
/// @author zefram.eth
/// @notice Uses a combination of Chainlink price oracles and Uniswap V3 built-in TWAP oracles
/// to compute the value of a Uniswap V3 liquidity position without being vulnerable to flashloan
/// manipulation attacks.
contract UniV3LpOracle {
    /// -----------------------------------------------------------------------
    /// Libraries usage
    /// -----------------------------------------------------------------------

    using SafeCastLib for uint256;
    using FixedPointMathLib for uint256;

    /// -----------------------------------------------------------------------
    /// Constants
    /// -----------------------------------------------------------------------

    uint256 internal constant PRICE_BASE = 1e8; // chainlink uses 8 decimals for prices
    uint256 internal constant BASE = 1e18; // result of quoteUSD uses 18 decimals

    /// -----------------------------------------------------------------------
    /// Immutable args
    /// -----------------------------------------------------------------------

    /// @notice The Chainlink Feed Registry contract
    /// @dev Since the Feed Registry only exists on Ethereum, this value will be
    /// address(0) on non-Ethereum networks.
    FeedRegistryInterface public immutable chainlink;

    address internal immutable WETH;
    address internal immutable WBTC;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error UniV3LpOracle__ChainlinkPriceTooOld();
    error UniV3LpOracle__NoChainlinkPriceAvailable();

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(FeedRegistryInterface chainlink_, address WETH_, address WBTC_) {
        chainlink = chainlink_;
        WETH = WETH_;
        WBTC = WBTC_;
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @notice Computes the USD value of a Uniswap V3 liquidity position.
    /// @dev This function is meant for ease of use: the number of input parameters is minimized
    /// and we make external contract calls to obtain the token & price feed addresses. Only works
    /// on Ethereum since the Feed Registry is only available there.
    /// @param pool The Uniswap V3 pool
    /// @param tickLower The lower tick of the liquidity position
    /// @param tickUpper The upper tick of the liquidity position
    /// @param liquidity The liquidity value of the position
    /// @param uniV3OracleSecondsAgo The size of the TWAP window used by the Uniswap V3 TWAP oracle in seconds.
    /// Ignored if both token0 and token1 have chainlink price feeds. The call reverts if the TWAP oracle
    /// doesn't have observations old enough in the past to support the window size.
    /// @param chainlinkPriceMaxAgeSecs The maximum age of the results returned by chainlink in seconds.
    /// The call reverts if the result is older than this value.
    /// @return valueUSD The value of the liquidity position in USD, 18 decimals
    function quoteUSD(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint32 uniV3OracleSecondsAgo,
        uint256 chainlinkPriceMaxAgeSecs
    ) external view returns (uint256 valueUSD) {
        address token0 = pool.token0();
        address token1 = pool.token1();

        AggregatorV2V3Interface feed0;
        AggregatorV2V3Interface feed1;
        try chainlink.getFeed(_transformToken(token0), Denominations.USD) returns (AggregatorV2V3Interface f) {
            feed0 = f;
        } catch {}
        try chainlink.getFeed(_transformToken(token1), Denominations.USD) returns (AggregatorV2V3Interface f) {
            feed1 = f;
        } catch {}

        uint256 token0Base = 10 ** uint256(ERC20(token0).decimals());
        uint256 token1Base = 10 ** uint256(ERC20(token1).decimals());

        return _quoteUSD(
            pool,
            token0,
            token1,
            token0Base,
            token1Base,
            tickLower,
            tickUpper,
            liquidity,
            uniV3OracleSecondsAgo,
            chainlinkPriceMaxAgeSecs,
            feed0,
            feed1
        );
    }

    /// @notice Computes the USD value of a Uniswap V3 liquidity position.
    /// @dev This function is meant for maximum gas efficiency: many parameters that could've been fetched
    /// via external calls are instead input arguments. Furthermore, this function must be used on non-Ethereum
    /// chains since there's no Feed Registry available. If the wrong values are given for input arguments, the result
    /// is undefined.
    /// @param pool The Uniswap V3 pool
    /// @param token0 token0 of the Uniswap pool
    /// @param token1 token1 of the Uniswap pool
    /// @param token0Base 10 ** token0Decimals
    /// @param token1Base 10 ** token1Decimals
    /// @param tickLower The lower tick of the liquidity position
    /// @param tickUpper The upper tick of the liquidity position
    /// @param liquidity The liquidity value of the position
    /// @param uniV3OracleSecondsAgo The size of the TWAP window used by the Uniswap V3 TWAP oracle in seconds.
    /// Ignored if both token0 and token1 have chainlink price feeds. The call reverts if the TWAP oracle
    /// doesn't have observations old enough in the past to support the window size.
    /// @param chainlinkPriceMaxAgeSecs The maximum age of the results returned by chainlink in seconds.
    /// The call reverts if the result is older than this value.
    /// @param feed0 The Chainlink price feed for token0. Use address(0) if not available.
    /// @param feed1 The Chainlink price feed for token1. Use address(0) if not available.
    /// @return valueUSD The value of the liquidity position in USD, 18 decimals
    function quoteUSD(
        IUniswapV3Pool pool,
        address token0,
        address token1,
        uint256 token0Base,
        uint256 token1Base,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint32 uniV3OracleSecondsAgo,
        uint256 chainlinkPriceMaxAgeSecs,
        AggregatorV2V3Interface feed0,
        AggregatorV2V3Interface feed1
    ) external view returns (uint256 valueUSD) {
        return _quoteUSD(
            pool,
            token0,
            token1,
            token0Base,
            token1Base,
            tickLower,
            tickUpper,
            liquidity,
            uniV3OracleSecondsAgo,
            chainlinkPriceMaxAgeSecs,
            feed0,
            feed1
        );
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    function _quoteUSD(
        IUniswapV3Pool pool,
        address token0,
        address token1,
        uint256 token0Base,
        uint256 token1Base,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint32 uniV3OracleSecondsAgo,
        uint256 chainlinkPriceMaxAgeSecs,
        AggregatorV2V3Interface feed0,
        AggregatorV2V3Interface feed1
    ) internal view returns (uint256 valueUSD) {
        uint256 price0USD;
        uint256 price1USD;

        // handle different cases based on availability of chainlink price feed
        {
            if (address(feed0) != address(0) && address(feed1) != address(0)) {
                // both tokens have chainlink price

                // fetch prices from chainlink
                price0USD = _getPriceUSDFromFeed(feed0, token0, chainlinkPriceMaxAgeSecs);
                price1USD = _getPriceUSDFromFeed(feed1, token1, chainlinkPriceMaxAgeSecs);
            } else if (address(feed0) != address(0) && address(feed1) == address(0)) {
                // token0 has chainlink price

                // fetch prices from chainlink
                price0USD = _getPriceUSDFromFeed(feed0, token0, chainlinkPriceMaxAgeSecs);

                // compute price1USD using Uniswap v3 TWAP oracle
                (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), uniV3OracleSecondsAgo);
                uint256 quoteAmount =
                    OracleLibrary.getQuoteAtTick(arithmeticMeanTick, token1Base.safeCastTo128(), token1, token0); // price of token1 in token0
                price1USD = quoteAmount.mulDivDown(price0USD, token0Base);
            } else if (address(feed0) == address(0) && address(feed1) != address(0)) {
                // token1 has chainlink price

                // fetch prices from chainlink
                price1USD = _getPriceUSDFromFeed(feed1, token1, chainlinkPriceMaxAgeSecs);

                // compute price0USD using Uniswap v3 TWAP oracle
                (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), uniV3OracleSecondsAgo);
                uint256 quoteAmount =
                    OracleLibrary.getQuoteAtTick(arithmeticMeanTick, token0Base.safeCastTo128(), token0, token1); // price of token0 in token1
                price0USD = quoteAmount.mulDivDown(price1USD, token1Base);
            } else {
                // neither token has chainlink price
                // cannot compute USD price in this case
                revert UniV3LpOracle__NoChainlinkPriceAvailable();
            }
        }

        // use token prices to compute sqrtRatioX96 and then compute token amounts for liquidity
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _getSqrtRatioX96(price0USD, price1USD),
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            liquidity
        );

        // add up position value of both tokens
        valueUSD = amount0.mulDivDown(price0USD, PRICE_BASE).mulDivDown(BASE, token0Base)
            + amount1.mulDivDown(price1USD, PRICE_BASE).mulDivDown(BASE, token1Base);
    }

    function _getPriceUSDFromFeed(AggregatorV2V3Interface feed, address token, uint256 chainlinkPriceMaxAgeSecs)
        internal
        view
        returns (uint256 priceUSD)
    {
        // fetch USD price of tokens from chainlink
        // prices use 8 decimals
        int256 priceUSDInt;
        uint256 updatedAt;
        try feed.latestRoundData() returns (uint80, int256 p, uint256, uint256 u, uint80) {
            priceUSDInt = p;
            updatedAt = u;
        } catch {
            // might be access controlled aggregator
            // use FeedRegistry instead to bypass access control
            (, priceUSDInt,, updatedAt,) = chainlink.latestRoundData(_transformToken(token), Denominations.USD);
        }

        // revert if the result is stale
        if (block.timestamp - updatedAt > chainlinkPriceMaxAgeSecs) revert UniV3LpOracle__ChainlinkPriceTooOld();

        return uint256(priceUSDInt);
    }

    function _getSqrtRatioX96(uint256 price0USD, uint256 price1USD) internal pure returns (uint160) {
        // sqrtRatioX96 = sqrt(amount1 / amount0) * 2**96
        //              = sqrt(price0USD / price1USD) * 2**96
        //              = sqrt(price0USD * 2**96 / price1USD) * 2**48
        return (((price0USD << 96) / price1USD).sqrt() << 48).safeCastTo160();
    }

    function _transformToken(address token) internal view returns (address) {
        // transforms WETH and WBTC to addresses accepted by chainlink
        if (token == WETH) {
            return Denominations.ETH;
        } else if (token == WBTC) {
            return Denominations.BTC;
        } else {
            return token;
        }
    }
}
