// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {RevenueModule} from "contracts/modules/RevenueModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {ModuleManager} from "contracts/modules/manager/ModuleManager.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract TestDeployTakasureReserve is Script {
    BenefitMultiplierConsumerMock bmConsumerMock;
    ModuleManager moduleManager;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ADMIN_ROLE = keccak256("MINTER_ADMIN_ROLE");
    bytes32 public constant BURNER_ADMIN_ROLE = keccak256("BURNER_ADMIN_ROLE");

    address takasureReserveImplementation;
    address userRouterImplementation;

    string root;
    string scriptPath;

    function run()
        external
        returns (
            address tsToken,
            BenefitMultiplierConsumerMock,
            address takasureReserve,
            address entryModule,
            address memberModule,
            address revenueModule,
            address revShareModule,
            address router,
            address referralGatewayProxy,
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

        referralGatewayProxy = _deployReferralGateway(
            config.takadaoOperator,
            config.kycProvider,
            config.pauseGuardian,
            config.contributionToken,
            address(bmConsumerMock)
        );

        moduleManager = new ModuleManager();

        // Deploy TakasureReserve
        takasureReserveImplementation = address(new TakasureReserve());
        takasureReserve = UnsafeUpgrades.deployUUPSProxy(
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

        (entryModule, memberModule, revenueModule, revShareModule) = _deployModules(
            takasureReserve,
            address(referralGatewayProxy),
            makeAddr("ccipReceiverContract"),
            makeAddr("couponPool"),
            config.takadaoOperator,
            address(moduleManager),
            config.contributionToken
        );

        // Deploy router
        userRouterImplementation = address(new UserRouter());
        router = UnsafeUpgrades.deployUUPSProxy(
            userRouterImplementation,
            abi.encodeCall(UserRouter.initialize, (takasureReserve, entryModule, memberModule))
        );

        _setContracts(entryModule, memberModule, revenueModule);

        TSToken creditToken = TSToken(TakasureReserve(takasureReserve).getReserveValues().daoToken);
        tsToken = address(creditToken);

        _assignRoles(takasureReserve, config.daoMultisig, creditToken, entryModule, memberModule);

        vm.stopBroadcast();

        contributionTokenAddress = TakasureReserve(takasureReserve)
            .getReserveValues()
            .contributionToken;

        return (
            tsToken,
            bmConsumerMock,
            takasureReserve,
            entryModule,
            memberModule,
            revenueModule,
            revShareModule,
            router,
            referralGatewayProxy,
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

    function _deployReferralGateway(
        address _takadaoOperator,
        address _kycProvider,
        address _pauseGuardian,
        address _contributionToken,
        address _bmConsumerMock
    ) internal returns (address referralGatewayProxy_) {
        address referralImplementation = address(new ReferralGateway());
        referralGatewayProxy_ = UnsafeUpgrades.deployUUPSProxy(
            referralImplementation,
            abi.encodeCall(
                ReferralGateway.initialize,
                (
                    _takadaoOperator,
                    _kycProvider,
                    _pauseGuardian,
                    _contributionToken,
                    _bmConsumerMock
                )
            )
        );
    }

    address revShareModuleImplementation;
    address entryModuleImplementation;
    address memberModuleImplementation;
    address revenueModuleImplementation;

    function _deployModules(
        address _takasureReserve,
        address _prejoinModule,
        address _ccipReceiver,
        address _couponPool,
        address _takadaoOperator,
        address _moduleManagerAddress,
        address _contributionToken
    )
        internal
        returns (
            address entryModule,
            address memberModule,
            address revenueModule,
            address revShareModule
        )
    {
        {
            // Deploy RevShareModule
            revShareModuleImplementation = address(new RevShareModule());
            revShareModule = UnsafeUpgrades.deployUUPSProxy(
                revShareModuleImplementation,
                abi.encodeCall(
                    RevShareModule.initialize,
                    (
                        _takadaoOperator,
                        _takadaoOperator,
                        _moduleManagerAddress,
                        _takasureReserve,
                        _contributionToken
                    )
                )
            );
        }
        {
            // Deploy EntryModule
            entryModuleImplementation = address(new EntryModule());
            entryModule = UnsafeUpgrades.deployUUPSProxy(
                entryModuleImplementation,
                abi.encodeCall(
                    EntryModule.initialize,
                    (_takasureReserve, _prejoinModule, _ccipReceiver, _couponPool, revShareModule)
                )
            );
        }
        {
            // Deploy MemberModule
            memberModuleImplementation = address(new MemberModule());
            memberModule = UnsafeUpgrades.deployUUPSProxy(
                memberModuleImplementation,
                abi.encodeCall(MemberModule.initialize, (_takasureReserve))
            );
        }
        {
            // Deploy RevenueModule
            revenueModuleImplementation = address(new RevenueModule());
            revenueModule = UnsafeUpgrades.deployUUPSProxy(
                revenueModuleImplementation,
                abi.encodeCall(RevenueModule.initialize, (_takasureReserve))
            );
        }
    }

    function _setContracts(
        address _entryModule,
        address _memberModule,
        address _revenueModule
    ) internal {
        // Setting EntryModule as a requester in BenefitMultiplierConsumer
        bmConsumerMock.setNewRequester(_entryModule);

        // Set modules contracts in TakasureReserve
        moduleManager.addModule(_entryModule);
        moduleManager.addModule(_memberModule);
        moduleManager.addModule(_revenueModule);
    }

    function _assignRoles(
        address _takasureReserve,
        address _daoMultisig,
        TSToken _creditToken,
        address _entryModule,
        address _memberModule
    ) internal {
        // After this set the dao multisig as the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(_takasureReserve).grantRole(0x00, _daoMultisig);
        // And the modules as burner and minters
        _creditToken.grantRole(MINTER_ROLE, _entryModule);
        _creditToken.grantRole(MINTER_ROLE, _memberModule);
        _creditToken.grantRole(BURNER_ROLE, _entryModule);
        _creditToken.grantRole(BURNER_ROLE, _memberModule);

        // And renounce the DEFAULT_ADMIN_ROLE in TakasureReserve
        TakasureReserve(_takasureReserve).renounceRole(0x00, msg.sender);
        // And the burner and minter admins
        _creditToken.renounceRole(MINTER_ADMIN_ROLE, msg.sender);
        _creditToken.renounceRole(BURNER_ADMIN_ROLE, msg.sender);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
