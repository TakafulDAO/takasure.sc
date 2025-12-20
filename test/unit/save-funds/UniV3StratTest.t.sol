// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {DeploySFUniV3Strategy} from "test/utils/07-DeploySFUniV3Strategy.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract UniV3StratTest is Test {
    using SafeERC20 for IERC20;

    DeployManagers internal managersDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    DeploySFUniV3Strategy internal uniV3StrategyDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3Strategy;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;

    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");

    uint256 internal constant MAX_BPS = 10_000;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Fork Arbitrum mainnet
        string memory rpcUrl = vm.envString("ARBITRUM_MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        managersDeployer = new DeployManagers();
        aggregatorDeployer = new DeploySFStrategyAggregator();
        uniV3StrategyDeployer = new DeploySFUniV3Strategy();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        address vaultImplementation = address(new SFVault());

        address vaultAddress = UnsafeUpgrades.deployUUPSProxy(
            vaultImplementation, abi.encodeCall(SFVault.initialize, (addrMgr, IERC20(ARB_USDC), "SF Vault", "SFV"))
        );

        vault = SFVault(vaultAddress);
        asset = IERC20(vault.asset());

        aggregator = aggregatorDeployer.run(addrMgr, asset, 100_000, address(vault));

        vm.startPrank(takadao);
        vault.whitelistToken(ARB_USDT);
        vault.setStrategy(ISFStrategy(address(aggregator)));
        vm.stopPrank();

        uniV3Strategy = uniV3StrategyDeployer.run(addrMgr, address(vault));

        // Fee recipient required by SFVault; not strictly needed for aggregator itself but kept consistent with other setup.
        feeRecipient = makeAddr("feeRecipient");
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("SF_VAULT_FEE_RECIPIENT", feeRecipient, ProtocolAddressType.Admin);

        // Ensure the vault is recognized as "PROTOCOL__SF_VAULT" for onlyContract checks.
        vm.startPrank(addrMgr.owner());
        if (!addrMgr.hasName("PROTOCOL__SF_VAULT", address(vault))) {
            addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Admin);
        }
        vm.stopPrank();

        // Pause guardian role for pause/unpause coverage
        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(uniV3Strategy), 10_000);
        vm.stopPrank();
    }

    function testSanity() public {
        assert(2 + 2 == 4);
    }
}

