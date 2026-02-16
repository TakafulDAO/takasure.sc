// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Client} from "ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "ccip/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";

import {SFAndIFCcipReceiver} from "contracts/helpers/chainlink/SFAndIFCcipReceiver.sol";
import {Protocols} from "contracts/helpers/chainlink/Protocols.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/Managers.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";

import {CCIPTestERC20, CCIPTestVault} from "test/unit/ccip/CCIPTestMocks.sol";

contract SFAndIFCcipReceiverForkTest is Test, GetContractAddress {
    uint256 private constant SAFE_BLOCK_LAG = 128;
    uint64 private constant SOURCE_CHAIN_SELECTOR = 1;

    IAddressManager internal addressManager;
    SFAndIFCcipReceiver internal receiver;
    CCIPTestERC20 internal usdc;
    CCIPTestVault internal sfVault;
    CCIPTestVault internal ifVault;

    address internal router;
    address internal allowedSender;
    address internal user;

    function setUp() public {
        _createAndSelectPinnedFork("arb_one");

        router = makeAddr("router");
        allowedSender = makeAddr("allowedSender");
        user = makeAddr("user");

        addressManager = IAddressManager(makeAddr("addressManager"));
        usdc = new CCIPTestERC20("USD Coin", "USDC", 6);

        sfVault = new CCIPTestVault(IERC20(address(usdc)));
        ifVault = new CCIPTestVault(IERC20(address(usdc)));

        receiver = new SFAndIFCcipReceiver(addressManager, router, address(usdc));
        receiver.toggleAllowedSender(SOURCE_CHAIN_SELECTOR, allowedSender);

        _mockProtocolAddress("PROTOCOL__SF_VAULT", address(sfVault));
        _mockProtocolAddress("PROTOCOL__IF_VAULT", address(ifVault));
    }

    function testSFAndIFCcip_receiver_processesSaveVaultMessageOnArbitrumFork() public {
        uint256 amount = 25e6;
        bytes32 messageId = keccak256("SAVE_SUCCESS");

        usdc.mint(address(receiver), amount);
        Client.Any2EVMMessage memory message =
            _buildValidMessage(messageId, Protocols.SAVE_VAULT, amount, user, allowedSender);

        vm.prank(router);
        receiver.ccipReceive(message);

        assertEq(sfVault.lastCaller(), address(receiver), "vault caller should be receiver");
        assertEq(sfVault.lastReceiver(), user, "wrong receiver");
        assertEq(sfVault.lastAssets(), amount, "wrong assets");
        assertEq(usdc.balanceOf(address(sfVault)), amount, "vault should receive USDC");
        assertEq(receiver.getFailedMessages(0, 10).length, 0, "there should be no failed messages");
    }

    function testSFAndIFCcip_receiver_processesInvestVaultMessageOnArbitrumFork() public {
        uint256 amount = 40e6;
        bytes32 messageId = keccak256("INVEST_SUCCESS");

        usdc.mint(address(receiver), amount);
        Client.Any2EVMMessage memory message =
            _buildValidMessage(messageId, Protocols.INVEST_VAULT, amount, user, allowedSender);

        vm.prank(router);
        receiver.ccipReceive(message);

        assertEq(ifVault.lastCaller(), address(receiver), "vault caller should be receiver");
        assertEq(ifVault.lastReceiver(), user, "wrong receiver");
        assertEq(ifVault.lastAssets(), amount, "wrong assets");
        assertEq(usdc.balanceOf(address(ifVault)), amount, "vault should receive USDC");
    }

    function testSFAndIFCcip_receiver_ccipReceiveRevertsWhenCallerIsNotRouter() public {
        Client.Any2EVMMessage memory message = _buildValidMessage(
            keccak256("NOT_ROUTER"), Protocols.SAVE_VAULT, 10e6, user, allowedSender
        );

        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(this)));
        receiver.ccipReceive(message);
    }

    function testSFAndIFCcip_receiver_ccipReceiveRevertsWhenSourceSenderIsNotAllowed() public {
        Client.Any2EVMMessage memory message =
            _buildValidMessage(keccak256("NOT_ALLOWED"), Protocols.SAVE_VAULT, 10e6, user, makeAddr("notAllowed"));

        vm.prank(router);
        vm.expectRevert(SFAndIFCcipReceiver.SFAndIFCcipReceiver__NotAllowedSource.selector);
        receiver.ccipReceive(message);
    }

    function testSFAndIFCcip_receiver_storesFailedMessageAndRetriesById() public {
        uint256 amount = 15e6;
        bytes32 messageId = keccak256("FAIL_THEN_RETRY");

        sfVault.setShouldRevert(true);
        usdc.mint(address(receiver), amount);

        Client.Any2EVMMessage memory message =
            _buildValidMessage(messageId, Protocols.SAVE_VAULT, amount, user, allowedSender);

        vm.prank(router);
        receiver.ccipReceive(message);

        bytes32[] memory ids = receiver.getFailedMessageIdsByUser(user);
        assertEq(ids.length, 1, "expected one failed message id");
        assertEq(ids[0], messageId, "wrong failed message id");
        assertEq(uint256(_statusById(messageId)), uint256(SFAndIFCcipReceiver.StatusCode.FAILED), "expected FAILED");

        sfVault.setShouldRevert(false);
        receiver.retryFailedMessageById(user, messageId);

        assertEq(uint256(_statusById(messageId)), uint256(SFAndIFCcipReceiver.StatusCode.RESOLVED), "expected RESOLVED");
        assertEq(sfVault.lastAssets(), amount, "retry should deposit assets");
    }

    function testSFAndIFCcip_receiver_recoverTokensByIdTransfersFundsBack() public {
        uint256 amount = 13e6;
        bytes32 messageId = keccak256("FAIL_THEN_RECOVER");

        sfVault.setShouldRevert(true);
        usdc.mint(address(receiver), amount);

        Client.Any2EVMMessage memory message =
            _buildValidMessage(messageId, Protocols.SAVE_VAULT, amount, user, allowedSender);

        vm.prank(router);
        receiver.ccipReceive(message);

        uint256 userBalanceBefore = usdc.balanceOf(user);
        receiver.recoverTokensById(user, messageId);
        uint256 userBalanceAfter = usdc.balanceOf(user);

        assertEq(userBalanceAfter - userBalanceBefore, amount, "user should receive recovered amount");
        assertEq(uint256(_statusById(messageId)), uint256(SFAndIFCcipReceiver.StatusCode.RECOVERED), "expected RECOVERED");
    }

    function testSFAndIFCcip_receiver_retryLatestAndRecoverLatestAcrossMultipleFailedMessages() public {
        uint256 firstAmount = 7e6;
        uint256 secondAmount = 9e6;
        bytes32 firstMessageId = keccak256("FIRST_FAILED");
        bytes32 secondMessageId = keccak256("SECOND_FAILED");

        sfVault.setShouldRevert(true);
        usdc.mint(address(receiver), firstAmount + secondAmount);

        Client.Any2EVMMessage memory first =
            _buildValidMessage(firstMessageId, Protocols.SAVE_VAULT, firstAmount, user, allowedSender);
        Client.Any2EVMMessage memory second =
            _buildValidMessage(secondMessageId, Protocols.SAVE_VAULT, secondAmount, user, allowedSender);

        vm.prank(router);
        receiver.ccipReceive(first);
        vm.prank(router);
        receiver.ccipReceive(second);

        sfVault.setShouldRevert(false);
        receiver.retryFailedMessage(user); // latest = secondMessageId
        receiver.recoverTokens(user); // remaining failed = firstMessageId

        assertEq(
            uint256(_statusById(secondMessageId)), uint256(SFAndIFCcipReceiver.StatusCode.RESOLVED), "second should resolve"
        );
        assertEq(
            uint256(_statusById(firstMessageId)), uint256(SFAndIFCcipReceiver.StatusCode.RECOVERED), "first should recover"
        );
    }

    function testSFAndIFCcip_receiver_malformedPayloadIsCapturedWithoutReverting() public {
        bytes32 messageId = keccak256("MALFORMED_DATA");

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: address(usdc), amount: 1e6});

        Client.Any2EVMMessage memory malformed = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(allowedSender),
            data: hex"1234",
            destTokenAmounts: destTokenAmounts
        });

        vm.prank(router);
        receiver.ccipReceive(malformed);

        bytes32[] memory zeroUserIds = receiver.getFailedMessageIdsByUser(address(0));
        assertEq(zeroUserIds.length, 1, "malformed payload should map to zero user");
        assertEq(zeroUserIds[0], messageId, "wrong failed id for zero user");
        assertEq(receiver.messageIdByUser(address(0)), messageId, "latest zero-user message id mismatch");
    }

    function testSFAndIFCcip_receiver_getFailedMessagesOutOfRangePaginationReturnsEmpty() public view {
        SFAndIFCcipReceiver.FailedMessage[] memory list = receiver.getFailedMessages(100, 10);
        assertEq(list.length, 0, "out of range pagination must return empty array");
    }

    function testSFAndIFCcip_receiver_retryRevertsWhenDestTokenArrayIsEmpty() public {
        bytes32 messageId = keccak256("EMPTY_TOKENS");

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory message = _buildMessage({
            messageId: messageId,
            protocolToCall: Protocols.SAVE_VAULT,
            protocolCallData: abi.encodeWithSignature("deposit(uint256,address)", 11e6, user),
            senderAddr: allowedSender,
            destTokenAmounts: destTokenAmounts
        });

        vm.prank(router);
        receiver.ccipReceive(message);

        vm.expectRevert(
            abi.encodeWithSelector(SFAndIFCcipReceiver.SFAndIFCcipReceiver__InvalidDestTokenAmountsLength.selector, 0)
        );
        receiver.retryFailedMessageById(user, messageId);
    }

    function testSFAndIFCcip_receiver_retryRevertsWhenDestTokenAddressIsInvalid() public {
        bytes32 messageId = keccak256("WRONG_TOKEN");
        CCIPTestERC20 notUsdc = new CCIPTestERC20("Not USDC", "NUSDC", 6);

        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: address(notUsdc), amount: 11e6});

        Client.Any2EVMMessage memory message = _buildMessage({
            messageId: messageId,
            protocolToCall: Protocols.SAVE_VAULT,
            protocolCallData: abi.encodeWithSignature("deposit(uint256,address)", 11e6, user),
            senderAddr: allowedSender,
            destTokenAmounts: destTokenAmounts
        });

        vm.prank(router);
        receiver.ccipReceive(message);

        vm.expectRevert(
            abi.encodeWithSelector(
                SFAndIFCcipReceiver.SFAndIFCcipReceiver__InvalidDestTokenAddress.selector, address(notUsdc)
            )
        );
        receiver.retryFailedMessageById(user, messageId);
    }

    function testSFAndIFCcip_receiver_retryRevertsWhenProtocolSelectorIsInvalid() public {
        bytes32 messageId = keccak256("INVALID_SELECTOR");
        uint256 amount = 5e6;

        usdc.mint(address(receiver), amount);

        Client.Any2EVMMessage memory message = _buildValidMessage(
            messageId,
            Protocols.SAVE_VAULT,
            amount,
            allowedSender,
            abi.encodeWithSignature("mint(uint256,address)", amount, user)
        );

        vm.prank(router);
        receiver.ccipReceive(message);

        bytes4 invalidSelector = bytes4(keccak256("mint(uint256,address)"));
        vm.expectRevert(
            abi.encodeWithSelector(
                SFAndIFCcipReceiver.SFAndIFCcipReceiver__InvalidProtocolCallSelector.selector, invalidSelector
            )
        );
        receiver.retryFailedMessageById(user, messageId);
    }

    function testSFAndIFCcip_receiver_usesProvidedArbitrumSFVaultAddressAndCapturesFailure() public {
        uint256 amount = 6e6;
        bytes32 messageId = keccak256("REAL_ARB_SF_VAULT");
        address arbOneSfVault = _getContractAddress(block.chainid, "SFVault");

        _mockProtocolAddress("PROTOCOL__SF_VAULT", arbOneSfVault);
        usdc.mint(address(receiver), amount);

        Client.Any2EVMMessage memory message =
            _buildValidMessage(messageId, Protocols.SAVE_VAULT, amount, user, allowedSender);

        vm.prank(router);
        receiver.ccipReceive(message);

        bytes32[] memory ids = receiver.getFailedMessageIdsByUser(user);
        assertEq(ids.length, 1, "should persist failed message for user");
        assertEq(ids[0], messageId, "wrong failed id");
        assertEq(receiver.userByMessageId(messageId), user, "wrong user linkage");
        assertEq(uint256(_statusById(messageId)), uint256(SFAndIFCcipReceiver.StatusCode.FAILED), "expected FAILED");
    }

    function _buildValidMessage(bytes32 messageId, uint256 protocolToCall, uint256 amount, address receiverAddr, address senderAddr)
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        return _buildValidMessage(
            messageId,
            protocolToCall,
            amount,
            senderAddr,
            abi.encodeWithSignature("deposit(uint256,address)", amount, receiverAddr)
        );
    }

    function _buildValidMessage(
        bytes32 messageId,
        uint256 protocolToCall,
        uint256 amount,
        address senderAddr,
        bytes memory protocolCallData
    ) internal view returns (Client.Any2EVMMessage memory) {
        Client.EVMTokenAmount[] memory destTokenAmounts = new Client.EVMTokenAmount[](1);
        destTokenAmounts[0] = Client.EVMTokenAmount({token: address(usdc), amount: amount});

        return _buildMessage({
            messageId: messageId,
            protocolToCall: protocolToCall,
            protocolCallData: protocolCallData,
            senderAddr: senderAddr,
            destTokenAmounts: destTokenAmounts
        });
    }

    function _buildMessage(
        bytes32 messageId,
        uint256 protocolToCall,
        bytes memory protocolCallData,
        address senderAddr,
        Client.EVMTokenAmount[] memory destTokenAmounts
    ) internal pure returns (Client.Any2EVMMessage memory) {
        return Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: SOURCE_CHAIN_SELECTOR,
            sender: abi.encode(senderAddr),
            data: abi.encode(protocolToCall, protocolCallData),
            destTokenAmounts: destTokenAmounts
        });
    }

    function _mockProtocolAddress(string memory name, address protocolAddr) internal {
        ProtocolAddress memory protocolAddress = ProtocolAddress({
            name: keccak256(bytes(name)),
            addr: protocolAddr,
            addressType: ProtocolAddressType.Protocol
        });

        vm.mockCall(
            address(addressManager),
            abi.encodeWithSelector(IAddressManager.getProtocolAddressByName.selector, name),
            abi.encode(protocolAddress)
        );
    }

    function _statusById(bytes32 messageId) internal view returns (SFAndIFCcipReceiver.StatusCode status) {
        SFAndIFCcipReceiver.FailedMessage[] memory list = receiver.getFailedMessages(0, 256);
        for (uint256 i; i < list.length; ++i) {
            if (list[i].messageId == messageId) return list[i].statusCode;
        }
        revert("status not found");
    }

    function _createAndSelectPinnedFork(string memory rpcAlias) internal returns (uint256 forkId, uint256 pinnedBlock) {
        string memory rpcUrl = vm.rpcUrl(rpcAlias);

        uint256 latestForkId = vm.createFork(rpcUrl);
        vm.selectFork(latestForkId);
        uint256 latestBlock = block.number;

        pinnedBlock = latestBlock > SAFE_BLOCK_LAG ? latestBlock - SAFE_BLOCK_LAG : latestBlock;
        forkId = vm.createFork(rpcUrl, pinnedBlock);
        vm.selectFork(forkId);
    }
}
