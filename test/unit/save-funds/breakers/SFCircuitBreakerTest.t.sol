// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {DeploySFAndIFCircuitBreaker} from "test/utils/08-DeployCircuitBreaker.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFAndIFCircuitBreaker} from "contracts/breakers/SFAndIFCircuitBreaker.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SFCircuitBreakerTest is Test {
    using SafeERC20 for IERC20;

    DeployManagers internal managersDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    DeploySFAndIFCircuitBreaker internal circuitBreakerDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3Strategy;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;
    SFAndIFCircuitBreaker internal circuitBreaker;

    IERC20 internal asset;
    IERC20 internal usdt;

    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");

    uint256 internal constant MAX_BPS = 10_000;

    // Arbitrum tokens
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    // Uniswap V3 addresses
    address internal constant POOL_USDC_USDT = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;

    int24 internal constant TICK_LOWER = -200;
    int24 internal constant TICK_UPPER = 200;

    function setUp() public {
        // Fork Arbitrum mainnet
        string memory rpcUrl = vm.envString("ARBITRUM_MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        managersDeployer = new DeployManagers();
        aggregatorDeployer = new DeploySFStrategyAggregator();
        circuitBreakerDeployer = new DeploySFAndIFCircuitBreaker();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));
        circuitBreaker = circuitBreakerDeployer.run(_addrMgr);

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        // Deploy a UUPS proxy for the vault
        address vaultImplementation = address(new SFVault());
        address vaultAddress = UnsafeUpgrades.deployUUPSProxy(
            vaultImplementation, abi.encodeCall(SFVault.initialize, (addrMgr, IERC20(ARB_USDC), "SF Vault", "SFV"))
        );
        vault = SFVault(vaultAddress);
        asset = IERC20(vault.asset());
        usdt = IERC20(ARB_USDT);

        // Deploy aggregator and set as vault strategy
        aggregator = aggregatorDeployer.run(addrMgr, asset, address(vault));

        vm.startPrank(takadao);
        vault.whitelistToken(ARB_USDT);
        vault.setAggregator(ISFStrategy(address(aggregator)));
        vm.stopPrank();

        // Fee recipient required by SFVault
        feeRecipient = makeAddr("feeRecipient");
        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__CIRCUIT_BREAKER", address(circuitBreaker), ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // Pause guardian role for pause/unpause coverage
        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(addrMgr.owner());
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, address(circuitBreaker));

        vm.prank(takadao);
        circuitBreaker.acceptPauserRole();

        // Deploy Uni V3 strategy (UUPS proxy)
        UniswapV3MathHelper mathHelper = new UniswapV3MathHelper();
        address stratImplementation = address(new SFUniswapV3Strategy());
        address stratProxy = UnsafeUpgrades.deployUUPSProxy(
            stratImplementation,
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    addrMgr,
                    address(vault),
                    IERC20(ARB_USDC),
                    IERC20(ARB_USDT),
                    POOL_USDC_USDT,
                    NONFUNGIBLE_POSITION_MANAGER,
                    address(mathHelper),
                    100_000e6, // max TVL (USDC 6 decimals)
                    UNIVERSAL_ROUTER,
                    TICK_LOWER,
                    TICK_UPPER
                )
            )
        );
        uniV3Strategy = SFUniswapV3Strategy(stratProxy);

        // The only strategy in the aggregator
        vm.prank(takadao);
        aggregator.addSubStrategy(address(uniV3Strategy), 10_000);
    }

    function testSanity() public pure {
        assert(2 + 2 == 4);
    }
}
