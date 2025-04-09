// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {ModuleManager} from "contracts/modules/manager/ModuleManager.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract TestDeployProtocol is Script {
    BenefitMultiplierConsumerMock bmConsumerMock;
    ModuleManager moduleManager;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");
    bytes32 public constant MODULE_MANAGER = keccak256("MODULE_MANAGER");

    address takasureReserveImplementation;
    address takasureReserve;
    address userRouterImplementation;

    string root;
    string scriptPath;

    function run()
        external
        returns (
            address tsToken,
            BenefitMultiplierConsumerMock,
            address takasureReserveAddress,
            address prejoinModuleAddress,
            address entryModuleAddress,
            address memberModuleAddress,
            address revenueModuleAddress,
            address revShareModuleAddress,
            address routerAddress,
            address contributionTokenAddress,
            address kycProvider,
            HelperConfig helperConfig
        )
    {
        helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Deploy the BenefitMultiplierConsumerMock
        bmConsumerMock = _deployBMConsumer(
            config.functionsRouter,
            config.donId,
            config.gasLimit,
            config.subscriptionId
        );

        moduleManager = new ModuleManager();

        // Deploy TakasureReserve
        takasureReserveImplementation = address(new TakasureReserve());
        takasureReserveAddress = UnsafeUpgrades.deployUUPSProxy(
            takasureReserveImplementation,
            abi.encodeCall(
                TakasureReserve.initialize,
                (
                    config.contributionToken,
                    config.feeClaimAddress,
                    config.daoMultisig,
                    config.takadaoOperator,
                    config.kycProvider,
                    config.pauseGuardian,
                    config.tokenAdmin,
                    address(moduleManager),
                    config.tokenName,
                    config.tokenSymbol
                )
            )
        );

        takasureReserve = takasureReserveAddress;

        (
            prejoinModuleAddress,
            entryModuleAddress,
            memberModuleAddress,
            revenueModuleAddress,
            revShareModuleAddress
        ) = _deployModules(
            config.takadaoOperator,
            config.kycProvider,
            config.contributionToken,
            address(bmConsumerMock),
            makeAddr("ccipReceiverContract"),
            makeAddr("couponPool"),
            address(moduleManager)
        );

        // Deploy router
        userRouterImplementation = address(new UserRouter());
        routerAddress = UnsafeUpgrades.deployUUPSProxy(
            userRouterImplementation,
            abi.encodeCall(
                UserRouter.initialize,
                (takasureReserve, entryModuleAddress, memberModuleAddress)
            )
        );

        _setContracts(entryModuleAddress, memberModuleAddress, revenueModuleAddress);

        TSToken creditToken = TSToken(TakasureReserve(takasureReserve).getReserveValues().daoToken);
        tsToken = address(creditToken);

        _assignRoles(config.daoMultisig, creditToken, entryModuleAddress, memberModuleAddress);

        vm.stopBroadcast();

        contributionTokenAddress = TakasureReserve(takasureReserve)
            .getReserveValues()
            .contributionToken;

        vm.prank(config.takadaoOperator);
        PrejoinModule(prejoinModuleAddress).grantRole(MODULE_MANAGER, address(moduleManager));

        vm.prank(moduleManager.owner());
        moduleManager.addModule(prejoinModuleAddress);

        return (
            tsToken,
            bmConsumerMock,
            takasureReserve,
            prejoinModuleAddress,
            entryModuleAddress,
            memberModuleAddress,
            revenueModuleAddress,
            revShareModuleAddress,
            routerAddress,
            contributionTokenAddress,
            kycProvider,
            helperConfig
        );
    }

    function _deployBMConsumer(
        address _functionsRouter,
        bytes32 _donId,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) internal returns (BenefitMultiplierConsumerMock bmConsumerMock_) {
        bmConsumerMock_ = new BenefitMultiplierConsumerMock(
            _functionsRouter,
            _donId,
            _gasLimit,
            _subscriptionId
        );
    }

    address prejoinModuleImplementation;
    address entryModuleImplementation;
    address memberModuleImplementation;
    address revenueModuleImplementation;
    address revShareModuleImplementation;

    function _deployModules(
        address _takadaoOperator,
        address _kycProvider,
        address _contributionToken,
        address _bmConsumerMock,
        address _ccipReceiver,
        address _couponPool,
        address _moduleManagerAddress
    )
        internal
        returns (
            address prejoinModuleAddress_,
            address entryModuleAddress_,
            address memberModuleAddress_,
            address revenueModuleAddress_,
            address revShareModuleAddress_
        )
    {
        // Deploy PrejoinModule
        prejoinModuleImplementation = address(new PrejoinModule());

        prejoinModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            prejoinModuleImplementation,
            abi.encodeCall(
                PrejoinModule.initialize,
                (_takadaoOperator, _kycProvider, _contributionToken, _bmConsumerMock)
            )
        );

        // Deploy RevShareModule
        revShareModuleImplementation = address(new RevShareModule());
        revShareModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            revShareModuleImplementation,
            abi.encodeCall(
                RevShareModule.initialize,
                (_takadaoOperator, _moduleManagerAddress, takasureReserve, _contributionToken)
            )
        );

        // Deploy EntryModule
        entryModuleImplementation = address(new EntryModule());
        entryModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            entryModuleImplementation,
            abi.encodeCall(
                EntryModule.initialize,
                (
                    takasureReserve,
                    prejoinModuleAddress_,
                    _ccipReceiver,
                    _couponPool,
                    revShareModuleAddress_
                )
            )
        );

        // Deploy MemberModule
        memberModuleImplementation = address(new MemberModule());
        memberModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            memberModuleImplementation,
            abi.encodeCall(MemberModule.initialize, (takasureReserve))
        );

        // Deploy RevenueModule
        revenueModuleImplementation = address(new RevenueModule());
        revenueModuleAddress_ = UnsafeUpgrades.deployUUPSProxy(
            revenueModuleImplementation,
            abi.encodeCall(RevenueModule.initialize, (takasureReserve))
        );
    }

    function _setContracts(
        address _entryModuleAddress,
        address _memberModuleAddress,
        address _revenueModuleAddress
    ) internal {
        // Setting EntryModule as a requester in BenefitMultiplierConsumer
        bmConsumerMock.setNewRequester(_entryModuleAddress);

        // Set modules contracts in TakasureReserve
        moduleManager.addModule(_entryModuleAddress);
        moduleManager.addModule(_memberModuleAddress);
        moduleManager.addModule(_revenueModuleAddress);
    }

    function _assignRoles(
        address _daoMultisig,
        TSToken _creditToken,
        address _entryModuleAddress,
        address _memberModuleAddress
    ) internal {
        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).grantRole(0x00, _daoMultisig);
        // And the modules as burner and minters
        _creditToken.grantRole(MINTER_ROLE, _entryModuleAddress);
        _creditToken.grantRole(MINTER_ROLE, _memberModuleAddress);
        _creditToken.grantRole(BURNER_ROLE, _entryModuleAddress);
        _creditToken.grantRole(BURNER_ROLE, _memberModuleAddress);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(takasureReserve).renounceRole(0x00, msg.sender);
        // And the burner and minter admins
        _creditToken.renounceRole(MINTER_ADMIN_ROLE, msg.sender);
        _creditToken.renounceRole(BURNER_ADMIN_ROLE, msg.sender);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
