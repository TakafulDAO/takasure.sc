// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract TestDeployTakasure is Script {
    BenefitMultiplierConsumerMock bmConsumerMock;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            TSToken,
            BenefitMultiplierConsumerMock,
            address takasurePoolProxy,
            address referralGatewayProxy,
            address contributionTokenAddress,
            address kycProvider,
            HelperConfig
        )
    {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast();

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

        takasurePoolProxy = _deployTakasurePool(
            config.contributionToken,
            config.feeClaimAddress,
            config.daoMultisig,
            config.takadaoOperator,
            config.kycProvider,
            config.pauseGuardian,
            config.tokenAdmin,
            config.tokenName,
            config.tokenSymbol
        );

        TakasurePool takasurePool = TakasurePool(takasurePoolProxy);

        address daoTokenAddress = takasurePool.getDaoTokenAddress();

        TSToken daoToken = TSToken(daoTokenAddress);

        ReferralGateway referralGateway = ReferralGateway(referralGatewayProxy);

        bmConsumerMock.setNewRequester(address(referralGateway));

        vm.stopBroadcast();

        contributionTokenAddress = takasurePool.getContributionTokenAddress();
        kycProvider = config.kycProvider;

        return (
            daoToken,
            bmConsumerMock,
            takasurePoolProxy,
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

    function _deployTakasurePool(
        address _contributionToken,
        address _feeClaimAddress,
        address _daoMultisig,
        address _takadaoOperator,
        address _kycProvider,
        address _pauseGuardian,
        address _tokenAdmin,
        string memory _tokenName,
        string memory _tokenSymbol
    ) internal returns (address takasurePoolProxy_) {
        address takasureImplementation = address(new TakasurePool());
        takasurePoolProxy_ = UnsafeUpgrades.deployUUPSProxy(
            takasureImplementation,
            abi.encodeCall(
                TakasurePool.initialize,
                (
                    _contributionToken,
                    _feeClaimAddress,
                    _daoMultisig,
                    _takadaoOperator,
                    _kycProvider,
                    _pauseGuardian,
                    _tokenAdmin,
                    _tokenName,
                    _tokenSymbol
                )
            )
        );
    }
}
