// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title Computes the result of a swap within ticks
/// @notice Contains methods for computing the result of a swap within a single tick price range, i.e., a single tick.
library SwapMath {

    // 给定交换参数，计算交换一定金额或交换一定金额的结果
    /// @notice Computes the result of swapping some amount in, or amount out, given the parameters of the swap
    /// @dev The fee, plus the amount in, will never exceed the amount remaining if the swap's `amountSpecified` is positive
    /// @param sqrtRatioCurrentX96 The current sqrt price of the pool
    /// @param sqrtRatioTargetX96 The price that cannot be exceeded, from which the direction of the swap is inferred
    /// @param liquidity The usable liquidity
    // 剩余多少输入或输出量需要换入/换出
    // 允许为负数；换入为正数，换出为负数
    /// @param amountRemaining How much input or output amount is remaining to be swapped in/out
    // 从输入金额中提取的费用，以百分之一 BIP 表示
    /// @param feePips The fee taken from the input amount, expressed in hundredths of a bip
    /// @return sqrtRatioNextX96 The price after swapping the amount in/out, not to exceed the price target
    /// @return amountIn The amount to be swapped in, of either token0 or token1, based on the direction of the swap
    /// @return amountOut The amount to be received, of either token0 or token1, based on the direction of the swap
    /// @return feeAmount The amount of input that will be taken as a fee
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        // 通过比较当前价格和目标价格，确定交换方向
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        // amountRemaining 为正数代表是给定 token0 输入数量，计算 token1 的输出数量
        // amountRemaining 为负数代表是给定 token1 输出数量，计算 token0 的输入数量
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {  // 换入
            // 在交易之前，先计算当价格移动到交易区间的边界时，所需的手续费
            // 输入代币数量扣除手续费后的值
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);
            // 如果当前价格大于目标价格，
            // 则交换方向为token0->token1，那么需要的amountIn是token0的数量
            // 否则为token1->token0，需要的amountIn是token1数量
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);
            // 当前的流动性区间不能满足当前的交易
            if (amountRemainingLessFee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {  // 仍然在当前的价格区间内
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
            }
                
        } else {    // 换出
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }
        // 判断是否能够到达目标价
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // get the input/output amounts
        // 获取输入或输出的 token 数量
        if (zeroForOne) {
            // 根据是否到达目标价格，计算 amountIn/amountOut 的值
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // cap the output amount to not exceed the remaining output amount
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // 根据交易是否移动到价格边界来计算手续费的数额
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // we didn't reach the target, so take the remainder of the maximum input as fee
            // 没有达到上边界，现在的价格区间有足够的流动性来填满交易
            // 因此我们只需要返回填满交易所需的数量与实际数量的差额
            // 这里没有使用 amountRemainingLessFee，因为实际上的费用已经在重新计算 amountIn 的过程中考虑过了
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // 当目标价格已经达到，我们不能从整个 amountRemaining 减去费用
            // 因为现在的价格区间的流动性不足以完成交易
            // 因此，在这里的费用仅需考虑这个价格区间实际满足的交易数量即可
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }

    // 在进行交易输入/输出的计算时，和流动性的计算一样，也会遇到rounding的问题，处理原则：
    // 1. 当计算 output 时，使用 RoundDown，保证 Pool 不会出现坏账
    // 2. 当计算 input 时，使用 RoundUp，保证 pool 不会出现坏账
    // 3. 当通过 input 计算 P‾‾√时，如果 P‾‾√会减少，那么使用 RoundUp，这样可以保证 ΔP‾‾√被 RoundDown，
    //      在后续计算 output 时不会使 pool 出现坏账。反之 如果 P‾‾√会增大， 那么使用 RoundDown
    // 4. 当通过 output 计算 P‾‾√时，如果 P‾‾√会减少，那么使用 RoundDown，这样可以保证 ΔP‾‾√被 RoundUp，
    //      在后续计算 input 时不会使 pool 出现坏账。反之 如果 P‾‾√会增大， 那么使用 RoundUp

}

