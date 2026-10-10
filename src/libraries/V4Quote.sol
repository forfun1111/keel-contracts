// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {BitMath} from "v4-core/src/libraries/BitMath.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @notice Read-only exact-input simulation for static-fee v4 pools, excluding hook deltas.
/// @dev Mirrors v4's bitmap traversal, rounding, tick crossing and combined LP/protocol fee.
library V4Quote {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    struct State {
        uint160 price;
        int24 tick;
        uint128 liquidity;
        uint256 remaining;
        uint256 output;
        uint24 fee;
    }
    error InvalidQuote();
    error InsufficientLiquidity();
    error QuoteTooComplex();

    function exactInput(IPoolManager manager, PoolKey memory key, bool zeroForOne, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0 || amount > uint256(uint128(type(int128).max))) revert InvalidQuote();
        PoolId id = key.toId();
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        if (price == 0) revert InvalidQuote();
        uint16 directionalFee = zeroForOne ? protocolFee.getZeroForOneFee() : protocolFee.getOneForZeroFee();
        State memory s = State({
            price: price,
            tick: tick,
            liquidity: manager.getLiquidity(id),
            remaining: amount,
            output: 0,
            fee: directionalFee.calculateSwapFee(lpFee)
        });
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 steps = 0;
        while (s.remaining != 0 && s.price != limit) {
            if (++steps > 4096) revert QuoteTooComplex();
            (int24 next, bool initialized) = _next(manager, id, s.tick, key.tickSpacing, zeroForOne);
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            uint160 nextPrice = TickMath.getSqrtPriceAtTick(next);
            uint160 oldPrice = s.price;
            (uint160 newPrice, uint256 input, uint256 output, uint256 fee) = SwapMath.computeSwapStep(
                s.price,
                SwapMath.getSqrtPriceTarget(zeroForOne, nextPrice, limit),
                s.liquidity,
                -int256(s.remaining),
                s.fee
            );
            s.price = newPrice;
            s.remaining -= input + fee;
            s.output += output;
            if (newPrice == nextPrice) {
                if (initialized) {
                    (uint128 gross, int128 net) = manager.getTickLiquidity(id, next);
                    if (gross == 0) revert InvalidQuote();
                    s.liquidity = LiquidityMath.addDelta(s.liquidity, zeroForOne ? -net : net);
                }
                s.tick = zeroForOne ? next - 1 : next;
            } else if (newPrice != oldPrice) {
                s.tick = TickMath.getTickAtSqrtPrice(newPrice);
            }
        }
        if (s.remaining != 0 || s.output == 0) revert InsufficientLiquidity();
        return s.output;
    }

    function _next(IPoolManager manager, PoolId id, int24 tick, int24 spacing, bool lte)
        private
        view
        returns (int24 next, bool initialized)
    {
        int24 compressed = TickBitmap.compress(tick, spacing);
        if (!lte) ++compressed;
        (int16 word, uint8 bit) = TickBitmap.position(compressed);
        uint256 mask = lte ? type(uint256).max >> (255 - bit) : ~((uint256(1) << bit) - 1);
        uint256 masked = manager.getTickBitmap(id, word) & mask;
        initialized = masked != 0;
        if (lte) {
            next = (compressed - int24(uint24(initialized ? bit - BitMath.mostSignificantBit(masked) : bit)))
                * spacing;
        } else {
            next =
                (compressed
                        + int24(uint24(initialized ? BitMath.leastSignificantBit(masked) - bit : 255 - bit)))
                    * spacing;
        }
    }
}
