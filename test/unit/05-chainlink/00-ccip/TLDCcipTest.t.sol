// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TLDCcipSender} from "contracts/helpers/chainlink/ccip/TLDCcipSender.sol";
import {TLDCcipReceiver} from "contracts/helpers/chainlink/ccip/TLDCcipReceiver.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/src/v0.8/ccip/test/mocks/MockRouter.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract TLDCcipTest is Test {
    TestDeployProtocol deployer;
    TLDCcipSender sender;
    TLDCcipReceiver receiver;
    CcipHelperConfig ccipHelperConfig;
    HelperConfig helperConfig;
    PrejoinModule prejoinModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    TakasureReserve takasureReserve;
    MockCCIPRouter ccipRouter;
    IUSDC usdc;
    address takasureReserveAddress;
    address prejoinModuleAddress;
    address senderImplementationAddress;
    address senderAddress;
    address usdcAddress;
    address admin;
    address linkAddress = makeAddr("linkAddress");
    address senderOwner = makeAddr("senderOwner");
    address backend = makeAddr("backend");

    event OnNewSupportedToken(address token);
    event OnBackendProviderSet(address backendProvider);
    event OnProtocolGatewayChanged(
        address indexed oldProtocolGateway,
        address indexed newProtocolGateway
    );

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            prejoinModuleAddress,
            ,
            ,
            ,
            ,
            usdcAddress,
            ,

        ) = deployer.run();

        // HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        usdc = IUSDC(usdcAddress);

        // admin = config.daoMultisig;

        // vm.startPrank(admin);
        // takasureReserve.setNewContributionToken(address(usdc));
        // takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        // vm.stopPrank();

        // vm.startPrank(bmConsumerMock.admin());
        // bmConsumerMock.setNewRequester(takasureReserveAddress);
        // bmConsumerMock.setNewRequester(prejoinModuleAddress);
        // vm.stopPrank();

        ccipRouter = new MockCCIPRouter();

        receiver = new TLDCcipReceiver(address(ccipRouter), usdcAddress, prejoinModuleAddress);

        senderImplementationAddress = address(new TLDCcipSender());
        senderAddress = UnsafeUpgrades.deployUUPSProxy(
            senderImplementationAddress,
            abi.encodeCall(
                TLDCcipSender.initialize,
                (
                    address(ccipRouter),
                    linkAddress,
                    address(receiver),
                    3478487238524512106,
                    senderOwner,
                    backend
                )
            )
        );

        sender = TLDCcipSender(senderAddress);
    }

    function testGetChainSelector() public view {
        assertEq(sender.destinationChainSelector(), 3478487238524512106);
    }

    function testSenderSetSupportedToken() public {
        assert(!sender.isSupportedToken(usdcAddress));

        vm.prank(senderOwner);
        vm.expectEmit(false, false, false, false, address(sender));
        emit OnNewSupportedToken(usdcAddress);
        sender.addSupportedToken(usdcAddress);

        assert(sender.isSupportedToken(usdcAddress));
    }

    function testSenderSetSupportedTokenRevertsIfNotOwner() public {
        vm.prank(backend);
        vm.expectRevert();
        sender.addSupportedToken(usdcAddress);
    }

    function testSenderSetSupportedTokenRevertsIfTokenIsAddressZero() public setToken {
        vm.prank(senderOwner);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__AddressZeroNotAllowed.selector);
        sender.addSupportedToken(address(0));
    }

    modifier setToken() {
        vm.prank(senderOwner);
        sender.addSupportedToken(usdcAddress);
        _;
    }

    function testSenderSetSupportedTokenRevertsIfTokenAlreadySupported() public setToken {
        vm.prank(senderOwner);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__AlreadySupportedToken.selector);
        sender.addSupportedToken(usdcAddress);
    }

    function testSenderSetBackendProvider() public {
        assertEq(sender.backendProvider(), backend);

        vm.prank(senderOwner);
        vm.expectEmit(false, false, false, false, address(sender));
        emit OnBackendProviderSet(linkAddress);
        sender.setBackendProvider(linkAddress);

        assertEq(sender.backendProvider(), linkAddress);
    }

    function testSenderSetBackendProviderRevertsIfTokenIsAddressZero() public setToken {
        vm.prank(senderOwner);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__AddressZeroNotAllowed.selector);
        sender.setBackendProvider(address(0));
    }

    function testSenderSetBackendProviderRevertsIfNotOwner() public {
        vm.prank(backend);
        vm.expectRevert();
        sender.setBackendProvider(linkAddress);
    }

    function testSenderSetReceiverContract() public {
        assertEq(sender.receiverContract(), address(receiver));

        vm.prank(senderOwner);
        sender.setReceiverContract(linkAddress);

        assertEq(sender.receiverContract(), linkAddress);
    }

    function testSenderSetReceiverContractRevertsIfTokenIsAddressZero() public setToken {
        vm.prank(senderOwner);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__AddressZeroNotAllowed.selector);
        sender.setReceiverContract(address(0));
    }

    function testSenderSetReceiverContractRevertsIfNotOwner() public {
        vm.prank(backend);
        vm.expectRevert();
        sender.setReceiverContract(linkAddress);
    }

    function testReceiverSetAllowedSender() public {
        uint64 chainSelector = 3478487238524512106;

        assert(!receiver.isSenderAllowedByChain(chainSelector, senderAddress));

        vm.prank(receiver.owner());
        receiver.toggleAllowedSender(chainSelector, senderAddress);

        assert(receiver.isSenderAllowedByChain(chainSelector, senderAddress));

        vm.prank(receiver.owner());
        receiver.toggleAllowedSender(chainSelector, senderAddress);

        assert(!receiver.isSenderAllowedByChain(chainSelector, senderAddress));
    }

    function testReceiverSetAllowedSenderRevertsIfNotOwner() public {
        uint64 chainSelector = 3478487238524512106;

        vm.prank(backend);
        vm.expectRevert();
        receiver.toggleAllowedSender(chainSelector, senderAddress);
    }

    function testReceiverSetAllowedSenderRevertsIfSenderAddressIsZero() public {
        uint64 chainSelector = 3478487238524512106;

        vm.prank(receiver.owner());
        vm.expectRevert(TLDCcipReceiver.TLDCcipReceiver__NotAllowedSource.selector);
        receiver.toggleAllowedSender(chainSelector, address(0));
    }

    function testReceiverSetProtocolGateway() public {
        assertEq(receiver.protocolGateway(), prejoinModuleAddress);

        vm.prank(receiver.owner());
        vm.expectEmit(true, true, false, false, address(receiver));
        emit OnProtocolGatewayChanged(prejoinModuleAddress, linkAddress);
        receiver.setProtocolGateway(linkAddress);

        assertEq(receiver.protocolGateway(), linkAddress);
    }

    function testReceiverSetProtocolGatewayRevertsIfNotOwner() public {
        vm.prank(backend);
        vm.expectRevert();
        receiver.setProtocolGateway(linkAddress);
    }

    function testReceiverSetProtocolGatewayRevertsIfIsAddressIsZero() public {
        vm.prank(receiver.owner());
        vm.expectRevert(TLDCcipReceiver.TLDCcipReceiver__NotZeroAddress.selector);
        receiver.setProtocolGateway(address(0));
    }
}
