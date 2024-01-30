// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3PoolDeployer.sol';

import './UniswapV3Pool.sol';

contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    Parameters public override parameters;

    // 部署交易对池子合约
    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// @param factory The contract address of the Uniswap V3 factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The spacing between usable ticks
    function deploy(
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 组装部署参数
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        // 创建交易对：部署一个交易对池子合约
        // 通过 keccak256(abi.encode(token0, token1, fee)) 将 token0，token1，fee 三个参数进行 hash，并作为 salt 来创建合约
        // 因为指定了 salt，所以EVM会使用CREATE2指令来创建合约
        // 使用CREATE2的好处是只要 bytecode 和 salt 不变，那么创建的合约的地址也不会变
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        delete parameters;
    }

    /*
        使用 CREATE2 指令创建合约的好处：
        1. 可以在链下计算出已经创建的交易池合约的地址
        2. 其他合约不需要通过 UniswapV3Factory 中的接口来查询交易池地址，可以节省gas
        3. 合约地址不会因为 reorg 而改变
     */
}
