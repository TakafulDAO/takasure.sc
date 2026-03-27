// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {SFTwapValuator} from "contracts/saveFunds/valuator/SFTwapValuator.sol";
import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

interface IMintableUSDC {
    function mintUSDC(address to, uint256 amount) external;
}

interface IMintableUSDT {
    function mintUSDT(address to, uint256 amount) external;
}

contract MigrateSFToCcipUSDCArbSepolia is Script, DeployConstants, GetContractAddress {
    error MigrateSFToCcipUSDCArbSepolia__UnsupportedChainId(uint256 chainId);
    error MigrateSFToCcipUSDCArbSepolia__CallerMustBeOperator(address caller);
    error MigrateSFToCcipUSDCArbSepolia__CallerMustOwnAddressManager(address caller, address owner);
    error MigrateSFToCcipUSDCArbSepolia__VaultNotEmpty(uint256 totalSupply, uint256 idleAssets, uint256 aggregatorAssets);

    address private constant ARB_ONE_POOL = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    uint256 private constant MINT_AMOUNT = 10_000_000e6; // 10 million (6 decimals)
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    struct SaveFundsAddresses {
        address addressManager;
        address vault;
        address aggregator;
        address uniV3Strategy;
        address twapValuator;
        address newUsdc;
        address usdt;
    }

    struct MimicPoolParams {
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
    }

    function run() external {
        if (block.chainid != ARB_SEPOLIA_CHAIN_ID) {
            revert MigrateSFToCcipUSDCArbSepolia__UnsupportedChainId(block.chainid);
        }

        SaveFundsAddresses memory a = _resolveAddresses();
        MimicPoolParams memory params = _readArbOnePoolParams();

        uint256 arbSepoliaFork = vm.createFork(vm.rpcUrl("arb_sepolia"));
        vm.selectFork(arbSepoliaFork);
        require(block.chainid == ARB_SEPOLIA_CHAIN_ID, "Not Arbitrum Sepolia");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        _checkPermissions(a.addressManager, deployer);

        _upgradeSaveFundsContracts(a);
        address newPool = _executeMigration(a, params, deployer);

        vm.stopBroadcast();

        console2.log("AddressManager:", a.addressManager);
        console2.log("SFVault:", a.vault);
        console2.log("SFStrategyAggregator:", a.aggregator);
        console2.log("SFUniswapV3Strategy:", a.uniV3Strategy);
        console2.log("SFTwapValuator:", a.twapValuator);
        console2.log("New SFUSDC (CCIP):", a.newUsdc);
        console2.log("SFUSDT:", a.usdt);
        console2.log("New UniV3 Pool:", newPool);
    }

    function _executeMigration(SaveFundsAddresses memory a, MimicPoolParams memory params, address deployer)
        internal
        returns (address newPool_)
    {
        SFVault vault = SFVault(a.vault);
        SFStrategyAggregator aggregator = SFStrategyAggregator(a.aggregator);
        SFUniswapV3Strategy strategy = SFUniswapV3Strategy(a.uniV3Strategy);

        _cleanupIfNeeded(vault, aggregator, strategy, deployer);
        uint256 sweptOldUnderlyingAmount = _sweepVaultIdleUnderlyingIfNeeded(vault, deployer);

        uint24 newPoolFee;
        (newPool_, newPoolFee) = _createAndSeedUniV3Pool(a.newUsdc, a.usdt, params, deployer);

        _migrateUnderlyingRefs(vault, aggregator, strategy, a.newUsdc, newPool_);
        _refillVaultWithNewUnderlyingIfNeeded(a.newUsdc, address(vault), sweptOldUnderlyingAmount);
        _updateAddressManagerAndPayloads(a, newPool_, newPoolFee);
    }

    function _migrateUnderlyingRefs(
        SFVault vault,
        SFStrategyAggregator aggregator,
        SFUniswapV3Strategy strategy,
        address newUsdc,
        address newPool
    ) internal {
        vault.temporarySetUnderlyingAndWhitelist(newUsdc, true);
        strategy.temporarySetUnderlyingAndPool(IERC20(newUsdc), newPool);
        aggregator.temporarySetUnderlying(newUsdc);
    }

    function _updateAddressManagerAndPayloads(SaveFundsAddresses memory a, address newPool, uint24 newPoolFee) internal {
        SFTwapValuator(a.twapValuator).setValuationPool(a.usdt, newPool);
        SFStrategyAggregator(a.aggregator).setDefaultWithdrawPayload(
            a.uniV3Strategy, _buildDefaultWithdrawPayload(a.uniV3Strategy, a.usdt, a.newUsdc, newPoolFee)
        );
        AddressManager(a.addressManager).updateProtocolAddress("EXTERNAL__USDC", a.newUsdc);
    }

    function _resolveAddresses() internal view returns (SaveFundsAddresses memory a_) {
        uint256 chainId = block.chainid;
        a_.addressManager = _getContractAddress(chainId, "AddressManager");
        a_.vault = _getContractAddress(chainId, "SFVault");
        a_.aggregator = _getContractAddress(chainId, "SFStrategyAggregator");
        a_.uniV3Strategy = _getContractAddress(chainId, "SFUniswapV3Strategy");
        a_.twapValuator = _getContractAddress(chainId, "SFTwapValuator");
        a_.newUsdc = _getContractAddress(chainId, "SFUSDCCcipTestnet");
        a_.usdt = _getContractAddress(chainId, "SFUSDT");
    }

    function _checkPermissions(address addressManagerAddr, address deployer) internal view {
        AddressManager addressManager = AddressManager(addressManagerAddr);

        if (!addressManager.hasRole(Roles.OPERATOR, deployer)) {
            revert MigrateSFToCcipUSDCArbSepolia__CallerMustBeOperator(deployer);
        }

        address owner = addressManager.owner();
        if (owner != deployer) {
            revert MigrateSFToCcipUSDCArbSepolia__CallerMustOwnAddressManager(deployer, owner);
        }
    }

    function _upgradeSaveFundsContracts(SaveFundsAddresses memory a_) internal {
        Upgrades.upgradeProxy(a_.vault, "SFVault.sol", "");
        Upgrades.upgradeProxy(a_.aggregator, "SFStrategyAggregator.sol", "");
        Upgrades.upgradeProxy(a_.uniV3Strategy, "SFUniswapV3Strategy.sol", "");
    }

    function _cleanupIfNeeded(SFVault vault, SFStrategyAggregator aggregator, SFUniswapV3Strategy strategy, address receiver)
        internal
    {
        // Strategy cleanup first so aggregator sees post-unwind balances.
        if (strategy.positionTokenId() != 0 || IERC20(strategy.asset()).balanceOf(address(strategy)) != 0
            || strategy.otherToken().balanceOf(address(strategy)) != 0)
        {
            strategy.emergencyExit(receiver);
        }

        if (aggregator.totalAssets() != 0) {
            aggregator.emergencyExit(receiver);
        }

        uint256 vaultTotalSupply = vault.totalSupply();
        uint256 vaultIdle = vault.idleAssets();
        uint256 vaultAggAssets = vault.aggregatorAssets();
        // Outstanding shares and idle underlying are allowed and handled during migration.
        // Aggregator-managed assets must be fully unwound before switching the vault underlying.
        if (vaultAggAssets != 0) {
            revert MigrateSFToCcipUSDCArbSepolia__VaultNotEmpty(vaultTotalSupply, vaultIdle, vaultAggAssets);
        }
    }

    function _sweepVaultIdleUnderlyingIfNeeded(SFVault vault, address receiver) internal returns (uint256 sweptAmount_) {
        uint256 idle = vault.idleAssets();
        if (idle == 0) return 0;
        sweptAmount_ = vault.temporarySweepIdleUnderlying(receiver);
    }

    function _refillVaultWithNewUnderlyingIfNeeded(address newUsdc, address vault, uint256 amount) internal {
        if (amount == 0) return;
        IMintableUSDC(newUsdc).mintUSDC(vault, amount);
    }

    function _readArbOnePoolParams() internal returns (MimicPoolParams memory p_) {
        uint256 arbOneFork = vm.createFork(vm.rpcUrl("arb_one"));
        vm.selectFork(arbOneFork);

        IUniswapV3Pool mainnetPool = IUniswapV3Pool(ARB_ONE_POOL);
        p_.fee = mainnetPool.fee();
        p_.tickSpacing = mainnetPool.tickSpacing();
        (p_.sqrtPriceX96,,,,,,) = mainnetPool.slot0();
    }

    function _createAndSeedUniV3Pool(address usdc, address usdt, MimicPoolParams memory p_, address deployer)
        internal
        returns (address pool_, uint24 fee_)
    {
        fee_ = p_.fee;
        address positionManager = UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARB_SEPOLIA;

        IMintableUSDC(usdc).mintUSDC(deployer, MINT_AMOUNT);
        IMintableUSDT(usdt).mintUSDT(deployer, MINT_AMOUNT);

        IERC20(usdc).approve(positionManager, MINT_AMOUNT);
        IERC20(usdt).approve(positionManager, MINT_AMOUNT);

        INonfungiblePositionManager pm = INonfungiblePositionManager(positionManager);

        (address token0, address token1) = usdc < usdt ? (usdc, usdt) : (usdt, usdc);
        pool_ = pm.createAndInitializePoolIfNecessary(token0, token1, p_.fee, p_.sqrtPriceX96);

        int24 tickLower = _roundDownToSpacing(MIN_TICK, p_.tickSpacing);
        int24 tickUpper = _roundDownToSpacing(MAX_TICK, p_.tickSpacing);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: p_.fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: MINT_AMOUNT,
            amount1Desired: MINT_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            recipient: deployer,
            deadline: block.timestamp + 1 hours
        });

        pm.mint(params);
    }

    function _buildDefaultWithdrawPayload(address strategy, address usdt, address usdc, uint24 poolFee)
        internal
        pure
        returns (bytes memory payload_)
    {
        uint256 amountInBpsFlag = (uint256(1) << 255) | 10_000; // swap 100% of balance
        bytes memory path = abi.encodePacked(usdt, poolFee, usdc);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(strategy, amountInBpsFlag, uint256(0), path, true);

        bytes memory swapToUnderlyingData = abi.encode(inputs, uint256(0)); // deadline sentinel
        payload_ = abi.encode(uint16(0), bytes(""), swapToUnderlyingData, uint256(0), uint256(0), uint256(0));
    }

    function _roundDownToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 remainder = tick % spacing;
        if (remainder == 0) return tick;
        if (tick < 0) return tick - (spacing + remainder);
        return tick - remainder;
    }
}
