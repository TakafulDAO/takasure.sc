// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TLDCcipSender} from "contracts/helpers/chainlink/ccip/TLDCcipSender.sol";
import {TLDCcipReceiver} from "contracts/helpers/chainlink/ccip/TLDCcipReceiver.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/src/v0.8/ccip/test/mocks/MockRouter.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {BurnMintERC677} from "@chainlink/contracts-ccip/src/v0.8/shared/token/ERC677/BurnMintERC677.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract TLDCcipTest is Test {
    TestDeployProtocol deployer;
    TLDCcipSender sender;
    TLDCcipReceiver receiver;
    PrejoinModule prejoinModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    TakasureReserve takasureReserve;
    MockCCIPRouter ccipRouter;
    HelperConfig helperConfig;
    BurnMintERC677 public link;
    IUSDC usdc;
    address takasureReserveAddress;
    address prejoinModuleAddress;
    address senderImplementationAddress;
    address senderAddress;
    address usdcAddress;
    address admin;
    address linkAddress;
    address senderOwner = makeAddr("senderOwner");
    address backend = makeAddr("backend");
    address user = makeAddr("user");
    uint64 public chainSelector = 16015286601757825753;
    uint256 public constant LINK_INITIAL_AMOUNT = 100e18; // 100 LINK
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 LINK
    string tDaoName = "TheLifeDao";

    event OnNewSupportedToken(address token);
    event OnBackendProviderSet(address backendProvider);
    event OnTokensTransferred(
        bytes32 indexed messageId,
        uint256 indexed tokenAmount,
        uint256 indexed fees,
        address user
    );
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
            helperConfig
        ) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        usdc = IUSDC(usdcAddress);
        link = new BurnMintERC677("ChainLink Token", "LINK", 18, 10 ** 27);
        linkAddress = address(link);

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
                    chainSelector,
                    senderOwner,
                    backend
                )
            )
        );

        sender = TLDCcipSender(senderAddress);

        deal(linkAddress, senderAddress, LINK_INITIAL_AMOUNT);
        deal(usdcAddress, user, USDC_INITIAL_AMOUNT);

        admin = config.daoMultisig;

        // Config mocks
        vm.startPrank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        prejoinModule.setCCIPReceiverContract(address(receiver));
        vm.stopPrank();

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(prejoinModuleAddress);
        vm.stopPrank();
    }

    modifier createDao() {
        vm.startPrank(admin);
        prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();
        _;
    }

    function testGetChainSelector() public view {
        assertEq(sender.destinationChainSelector(), chainSelector);
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

    function testSenderWithdrawLink() public {
        assertEq(link.balanceOf(senderAddress), LINK_INITIAL_AMOUNT);
        assertEq(link.balanceOf(backend), 0);

        vm.prank(senderOwner);
        sender.withdrawLink(backend);

        assertEq(link.balanceOf(senderAddress), 0);
        assertEq(link.balanceOf(backend), LINK_INITIAL_AMOUNT);
    }

    modifier withdraw() {
        vm.prank(senderOwner);
        sender.withdrawLink(backend);
        _;
    }

    function testSenderWithdrawLinkRevertsIfNotOwner() public {
        assertEq(link.balanceOf(senderAddress), LINK_INITIAL_AMOUNT);
        assertEq(link.balanceOf(backend), 0);

        vm.prank(backend);
        vm.expectRevert();
        sender.withdrawLink(backend);

        assertEq(link.balanceOf(senderAddress), LINK_INITIAL_AMOUNT);
        assertEq(link.balanceOf(backend), 0);
    }

    function testSenderWithdrawLinkRevertsIfAddressIsZero() public {
        assertEq(link.balanceOf(senderAddress), LINK_INITIAL_AMOUNT);

        vm.prank(senderOwner);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__AddressZeroNotAllowed.selector);
        sender.withdrawLink(address(0));

        assertEq(link.balanceOf(senderAddress), LINK_INITIAL_AMOUNT);
    }

    function testReceiverSetAllowedSender() public {
        assert(!receiver.isSenderAllowedByChain(chainSelector, senderAddress));

        vm.prank(receiver.owner());
        receiver.toggleAllowedSender(chainSelector, senderAddress);

        assert(receiver.isSenderAllowedByChain(chainSelector, senderAddress));

        vm.prank(receiver.owner());
        receiver.toggleAllowedSender(chainSelector, senderAddress);

        assert(!receiver.isSenderAllowedByChain(chainSelector, senderAddress));
    }

    modifier setAllowedSender() {
        vm.prank(receiver.owner());
        receiver.toggleAllowedSender(chainSelector, senderAddress);
        _;
    }

    function testReceiverSetAllowedSenderRevertsIfNotOwner() public {
        vm.prank(backend);
        vm.expectRevert();
        receiver.toggleAllowedSender(chainSelector, senderAddress);
    }

    function testReceiverSetAllowedSenderRevertsIfSenderAddressIsZero() public {
        vm.prank(receiver.owner());
        vm.expectRevert(TLDCcipReceiver.TLDCcipReceiver__NotAllowedSource.selector);
        receiver.toggleAllowedSender(chainSelector, address(0));
    }

    function testSenderSendMesageRevertsIfNotSupportedToken() public {
        uint256 amountToTransfer = 100e6;
        uint256 gasLimit = 1000000;
        uint256 contribution = 100e6;
        string memory dao = "dao";

        vm.prank(user);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__NotSupportedToken.selector);
        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            contribution,
            dao,
            address(0),
            user,
            0
        );
    }

    function testSenderSendMesageRevertsIfNoContribution() public setToken {
        uint256 amountToTransfer = 0;
        uint256 gasLimit = 1000000;
        uint256 contribution = 50e6;
        uint256 coupon = 50e6;
        string memory dao = "dao";

        vm.prank(backend);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__ZeroTransferNotAllowed.selector);
        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            contribution,
            dao,
            address(0),
            user,
            coupon
        );
    }

    function testSenderSendMesageRevertsIfWrongContribution() public setToken {
        uint256 amountToTransfer = 100e6;
        uint256 gasLimit = 1000000;
        uint256 minContribution = 20e6;
        uint256 maxContribution = 300e6;
        string memory dao = "dao";

        vm.startPrank(user);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__ContributionOutOfRange.selector);
        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            minContribution,
            dao,
            address(0),
            user,
            0
        );

        vm.expectRevert(TLDCcipSender.TLDCcipSender__ContributionOutOfRange.selector);
        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            maxContribution,
            dao,
            address(0),
            user,
            0
        );
        vm.stopPrank();
    }

    function testSenderSendMesageRevertsIfTransferMoreThanContribution() public setToken {
        uint256 amountToTransfer = 100e6;
        uint256 gasLimit = 1000000;
        uint256 contribution = 50e6;
        string memory dao = "dao";

        vm.prank(user);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__WrongTransferAmount.selector);
        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            contribution,
            dao,
            address(0),
            user,
            0
        );
    }

    function testSenderSendMesageRevertsIfThereIsCouponAndCallerIsNotBackend() public setToken {
        uint256 amountToTransfer = 50e6;
        uint256 gasLimit = 1000000;
        uint256 contribution = 100e6;
        string memory dao = "dao";
        uint256 coupon = 50e6;

        vm.prank(user);
        vm.expectRevert(TLDCcipSender.TLDCcipSender__NotAuthorized.selector);
        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            contribution,
            dao,
            address(0),
            user,
            coupon
        );
    }

    function testSenderSuccessSendMesage() public setToken setAllowedSender {
        uint256 amountToTransfer = 100e6;
        uint256 gasLimit = 1000000;
        uint256 contribution = 100e6;

        bytes32 messageId = 0xe01b2be933401960d637314fd27f4fdf2caa6639d0f9ac6f78e7f21fe77c25d6;

        vm.startPrank(user);
        usdc.approve(senderAddress, amountToTransfer);

        vm.expectEmit(true, true, true, true, address(sender));
        emit OnTokensTransferred(messageId, amountToTransfer, 0, user);

        sender.sendMessage(
            amountToTransfer,
            usdcAddress,
            gasLimit,
            contribution,
            tDaoName,
            address(0),
            user,
            0
        );
        vm.stopPrank();
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
