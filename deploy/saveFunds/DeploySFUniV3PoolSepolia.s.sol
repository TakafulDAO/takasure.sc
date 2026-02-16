// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";

interface IMintableUSDC {
    function mintUSDC(address to, uint256 amount) external;
}

interface IMintableUSDT {
    function mintUSDT(address to, uint256 amount) external;
}

contract DeploySFUniV3PoolSepolia is Script, DeployConstants, GetContractAddress {
    address private constant ARB_ONE_POOL = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    uint256 private constant MINT_AMOUNT = 10_000_000e6; // 10 million (6 decimals)
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    function run() external {
        // Fetch pool params from Arbitrum One
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        {
            uint256 arbOneFork = vm.createFork(vm.rpcUrl("arb_one"));
            vm.selectFork(arbOneFork);
            IUniswapV3Pool mainnetPool = IUniswapV3Pool(ARB_ONE_POOL);
            fee = mainnetPool.fee();
            tickSpacing = mainnetPool.tickSpacing();
            (sqrtPriceX96,,,,,,) = mainnetPool.slot0();
            console2.log("Mainnet pool fee:", fee);
            console2.log("Mainnet pool tickSpacing:", tickSpacing);
            console2.log("Mainnet pool sqrtPriceX96:", sqrtPriceX96);
        }

        // Switch to Arbitrum Sepolia fork for deployment
        uint256 arbSepoliaFork = vm.createFork(vm.rpcUrl("arb_sepolia"));
        vm.selectFork(arbSepoliaFork);
        require(block.chainid == ARB_SEPOLIA_CHAIN_ID, "Not Arbitrum Sepolia");

        address usdc = _getContractAddress(block.chainid, "SFUSDC");
        address usdt = _getContractAddress(block.chainid, "SFUSDT");
        address positionManager = UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARB_SEPOLIA;

        (address token0, address token1) = usdc < usdt ? (usdc, usdt) : (usdt, usdc);
        // Keep mainnet price for initialization

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        // Mint tokens to deployer
        IMintableUSDC(usdc).mintUSDC(deployer, MINT_AMOUNT);
        IMintableUSDT(usdt).mintUSDT(deployer, MINT_AMOUNT);

        // Approve position manager
        IERC20(usdc).approve(positionManager, MINT_AMOUNT);
        IERC20(usdt).approve(positionManager, MINT_AMOUNT);

        _createPoolAndMint(positionManager, token0, token1, fee, sqrtPriceX96, tickSpacing, deployer);

        vm.stopBroadcast();
    }

    function _roundDownToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 remainder = _tick % _spacing;
        if (remainder == 0) return _tick;
        if (_tick < 0) {
            return _tick - (_spacing + remainder);
        }
        return _tick - remainder;
    }

    function _createPoolAndMint(
        address positionManager,
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        address recipient
    ) internal {
        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);
        address pool = pm.createAndInitializePoolIfNecessary(token0, token1, fee, sqrtPriceX96);
        console2.log("Sepolia pool:", pool);

        int24 tickLower = _roundDownToSpacing(MIN_TICK, tickSpacing);
        int24 tickUpper = _roundDownToSpacing(MAX_TICK, tickSpacing);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: MINT_AMOUNT,
            amount1Desired: MINT_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: block.timestamp + 1 hours
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = pm.mint(params);
        console2.log("Position tokenId:", tokenId);
        console2.log("Liquidity:", liquidity);
        console2.log("Amount0 used:", amount0);
        console2.log("Amount1 used:", amount1);
    }
}
