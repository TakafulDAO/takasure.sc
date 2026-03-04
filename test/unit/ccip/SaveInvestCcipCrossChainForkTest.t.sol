// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

import {SaveInvestCCIPSender} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPSender.sol";
import {SaveInvestCCIPReceiver} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPReceiver.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

interface ISFUSDCCcipTestnet is IERC20 {
    function mintUSDC(address to, uint256 amount) external;
}

interface IAddressManagerRoleReader {
    function currentRoleHolders(bytes32 role) external view returns (address roleHolder);
}

interface ISFVaultFork {
    function registerMember(address newMember) external;
    function maxDeposit(address receiver) external view returns (uint256);
    function userTotalDeposited(address user) external view returns (uint256 totalDeposited);
    function asset() external view returns (address);
}

contract SaveInvestCcipCrossChainForkTest is Test {
    string private constant ETH_SEPOLIA_RPC_ALIAS = "eth_sepolia";
    string private constant ARB_SEPOLIA_RPC_ALIAS = "arb_sepolia";

    address private constant ETH_SEPOLIA_SFUSDC = 0xA0224A609051308289f3AEa62fc0019086492A45;
    address private constant ARB_SEPOLIA_ADDRESS_MANAGER = 0xAA1b3Fc1f23c1baed05AEc2952A21A0AfCB740F6;
    address private constant ARB_SEPOLIA_SF_VAULT = 0x08037CF86aBbF960DA75ae3eAe9d2Fb8fe312A60;

    uint256 private constant SEND_AMOUNT = 125e6; // 125 SFUSDC (6 decimals)
    uint256 private constant LOW_GAS_LIMIT = 600_000;
    uint256 private constant HIGH_GAS_LIMIT = 1_200_000;
    uint256 private constant MAX_GAS_LIMIT = 1_200_000;
    string private constant SAVE_VAULT = "PROTOCOL__SF_VAULT";

    bytes32 private constant ON_MESSAGE_FAILED_TOPIC = keccak256("OnMessageFailed(bytes32,bytes,address)");
    bytes4 private constant SF_VAULT_NOT_A_MEMBER_SELECTOR = bytes4(keccak256("SFVault__NotAMember()"));

    address internal user;
    address internal unregisteredUser;

    uint256 internal sourceFork;
    uint256 internal destinationFork;

    Register.NetworkDetails internal sourceNetwork;
    Register.NetworkDetails internal destinationNetwork;

    CCIPLocalSimulatorFork internal ccipLocalSimulatorFork;

    SaveInvestCCIPSender internal sender;
    SaveInvestCCIPReceiver internal receiver;
    IAddressManager internal addressManager;
    ISFVaultFork internal sfVault;
    ISFUSDCCcipTestnet internal sourceToken;
    IERC20 internal destinationToken;

    function setUp() public {
        user = makeAddr("user");
        unregisteredUser = makeAddr("unregisteredUser");

        sourceFork = vm.createSelectFork(vm.rpcUrl(ETH_SEPOLIA_RPC_ALIAS));
        destinationFork = vm.createFork(vm.rpcUrl(ARB_SEPOLIA_RPC_ALIAS));

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        sourceNetwork = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        vm.selectFork(destinationFork);
        destinationNetwork = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        addressManager = IAddressManager(ARB_SEPOLIA_ADDRESS_MANAGER);
        sfVault = ISFVaultFork(ARB_SEPOLIA_SF_VAULT);
        destinationToken = IERC20(sfVault.asset());

        if (sfVault.maxDeposit(unregisteredUser) > 0) {
            unregisteredUser = makeAddr("unregisteredUser2");
        }
        require(sfVault.maxDeposit(unregisteredUser) == 0, "failed to find unregistered user");

        receiver = new SaveInvestCCIPReceiver(
            addressManager, destinationNetwork.routerAddress, address(destinationToken), address(this)
        );

        vm.selectFork(sourceFork);
        sourceToken = ISFUSDCCcipTestnet(ETH_SEPOLIA_SFUSDC);
        sender = _deploySenderProxy(address(this), destinationNetwork.chainSelector, address(receiver));
        sender.setMaxGasLimit(MAX_GAS_LIMIT);
        sender.setSupportedProtocol(SAVE_VAULT, true);

        vm.selectFork(destinationFork);
        receiver.toggleAllowedSender(sourceNetwork.chainSelector, address(sender));
        _ensureUserRegisteredInSFVault(user);

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sender), 20 ether);
        _fundAndApproveSourceUser(user, SEND_AMOUNT * 4);
        _fundAndApproveSourceUser(unregisteredUser, SEND_AMOUNT * 4);
    }

    function testSaveInvestCCIP_crossChain_happyPathUserDepositsWith1200000Gas() public {
        vm.selectFork(destinationFork);
        uint256 depositedBefore = sfVault.userTotalDeposited(user);
        uint256 failedBefore = receiver.getFailedMessageIdsByUser(user).length;

        vm.selectFork(sourceFork);
        uint256 sourceBalanceBefore = sourceToken.balanceOf(user);

        vm.prank(user);
        bytes32 messageId = sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, HIGH_GAS_LIMIT);
        assertNotEq(messageId, bytes32(0), "messageId should not be zero");
        assertEq(sourceToken.balanceOf(user), sourceBalanceBefore - SEND_AMOUNT, "source balance mismatch");

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        vm.selectFork(destinationFork);
        assertEq(sfVault.userTotalDeposited(user) - depositedBefore, SEND_AMOUNT, "vault deposited amount mismatch");
        assertEq(receiver.getFailedMessageIdsByUser(user).length, failedBefore, "happy path should not fail");
    }

    function testSaveInvestCCIP_crossChain_lowGasRevertsAndDoesNotEmitOnMessageFailed() public {
        vm.selectFork(destinationFork);
        uint256 failedBefore = receiver.getFailedMessageIdsByUser(unregisteredUser).length;

        vm.recordLogs();
        vm.selectFork(sourceFork);
        vm.prank(unregisteredUser);
        bytes32 messageId = sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, LOW_GAS_LIMIT);
        assertNotEq(messageId, bytes32(0), "messageId should not be zero");

        vm.selectFork(sourceFork);
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found,) = _extractOnMessageFailedReason(logs, messageId, unregisteredUser);
        assertFalse(found, "OnMessageFailed should not be emitted when routing runs out of gas");

        vm.selectFork(destinationFork);
        assertEq(
            receiver.getFailedMessageIdsByUser(unregisteredUser).length,
            failedBefore,
            "failed ids should not change when route reverts"
        );
        assertEq(receiver.messageIdByUser(unregisteredUser), bytes32(0), "message should not be tracked as failed");
    }

    function testSaveInvestCCIP_crossChain_highGasFailsAsNotMemberAndEmitsOnMessageFailed() public {
        vm.recordLogs();
        vm.selectFork(sourceFork);
        vm.prank(unregisteredUser);
        bytes32 messageId = sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, HIGH_GAS_LIMIT);
        assertNotEq(messageId, bytes32(0), "messageId should not be zero");

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found, bytes memory reason) = _extractOnMessageFailedReason(logs, messageId, unregisteredUser);
        assertTrue(found, "OnMessageFailed should be emitted for high-gas member-check failure");

        bytes memory innerReason = _decodeInnerFailureReason(reason);
        assertGe(innerReason.length, 4, "inner reason must include selector");

        bytes4 innerSelector;
        assembly {
            innerSelector := mload(add(innerReason, 0x20))
        }
        assertEq(innerSelector, SF_VAULT_NOT_A_MEMBER_SELECTOR, "expected SFVault__NotAMember");

        vm.selectFork(destinationFork);
        assertEq(receiver.messageIdByUser(unregisteredUser), messageId, "failed message id should be tracked");
        assertEq(receiver.userByMessageId(messageId), unregisteredUser, "failed message user mismatch");
    }

    function testSaveInvestCCIP_crossChain_userCanRecoverTokensAfterFailedMessage() public {
        bytes32 messageId = _sendFailingMessageForUnregisteredUser(HIGH_GAS_LIMIT);

        vm.selectFork(destinationFork);
        uint256 balanceBefore = destinationToken.balanceOf(unregisteredUser);

        vm.prank(unregisteredUser);
        receiver.recoverTokensById(unregisteredUser, messageId);

        assertEq(
            destinationToken.balanceOf(unregisteredUser) - balanceBefore,
            SEND_AMOUNT,
            "user should recover full bridged amount"
        );
        assertEq(
            uint256(_statusById(messageId)),
            uint256(SaveInvestCCIPReceiver.StatusCode.RECOVERED),
            "message status should be RECOVERED"
        );
    }

    function testSaveInvestCCIP_crossChain_userCanRetryAfterRegistrationAndSucceed() public {
        bytes32 messageId = _sendFailingMessageForUnregisteredUser(HIGH_GAS_LIMIT);

        vm.selectFork(destinationFork);
        uint256 depositedBefore = sfVault.userTotalDeposited(unregisteredUser);

        _ensureUserRegisteredInSFVault(unregisteredUser);

        vm.prank(unregisteredUser);
        receiver.retryFailedMessageById(unregisteredUser, messageId);

        assertEq(
            sfVault.userTotalDeposited(unregisteredUser) - depositedBefore,
            SEND_AMOUNT,
            "retry should deposit into SFVault"
        );
        assertEq(
            uint256(_statusById(messageId)),
            uint256(SaveInvestCCIPReceiver.StatusCode.RESOLVED),
            "message status should be RESOLVED"
        );
    }

    function _sendFailingMessageForUnregisteredUser(uint256 gasLimit) internal returns (bytes32 messageId_) {
        vm.recordLogs();
        vm.selectFork(sourceFork);
        vm.prank(unregisteredUser);
        messageId_ = sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, gasLimit);

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (bool found,) = _extractOnMessageFailedReason(logs, messageId_, unregisteredUser);
        assertTrue(found, "expected OnMessageFailed event for unregistered user");
    }

    function _deploySenderProxy(address _owner, uint64 _destinationChainSelector, address _receiverContract)
        internal
        returns (SaveInvestCCIPSender sender_)
    {
        address implementation = address(new SaveInvestCCIPSender());
        bytes memory initData = abi.encodeWithSelector(
            SaveInvestCCIPSender.initialize.selector,
            sourceNetwork.routerAddress,
            sourceNetwork.linkAddress,
            address(sourceToken),
            _receiverContract,
            _destinationChainSelector,
            _owner
        );

        sender_ = SaveInvestCCIPSender(UnsafeUpgrades.deployUUPSProxy(implementation, initData));
    }

    function _fundAndApproveSourceUser(address _user, uint256 _amount) internal {
        sourceToken.mintUSDC(_user, _amount);
        vm.prank(_user);
        sourceToken.approve(address(sender), type(uint256).max);
    }

    function _ensureUserRegisteredInSFVault(address member) internal {
        if (sfVault.maxDeposit(member) > 0) return;

        address backendAdmin =
            IAddressManagerRoleReader(address(addressManager)).currentRoleHolders(Roles.BACKEND_ADMIN);
        require(backendAdmin != address(0), "missing BACKEND_ADMIN");

        vm.prank(backendAdmin);
        sfVault.registerMember(member);

        assertGt(sfVault.maxDeposit(member), 0, "user should be registered in SFVault");
    }

    function _extractOnMessageFailedReason(Vm.Log[] memory logs, bytes32 messageId, address expectedUser)
        internal
        view
        returns (bool found, bytes memory reason)
    {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != address(receiver)) continue;
            if (log.topics.length != 2) continue;
            if (log.topics[0] != ON_MESSAGE_FAILED_TOPIC) continue;
            if (log.topics[1] != messageId) continue;

            (bytes memory reason_, address user_) = abi.decode(log.data, (bytes, address));
            if (user_ != expectedUser) continue;
            return (true, reason_);
        }
    }

    function _decodeInnerFailureReason(bytes memory receiverReason) internal pure returns (bytes memory innerReason_) {
        if (receiverReason.length < 4) return bytes("");

        bytes4 outerSelector;
        assembly {
            outerSelector := mload(add(receiverReason, 0x20))
        }
        if (outerSelector != SaveInvestCCIPReceiver.SaveInvestCCIPReceiver__CallFailed.selector) {
            return bytes("");
        }

        bytes memory encodedArgs = new bytes(receiverReason.length - 4);
        for (uint256 i; i < encodedArgs.length; ++i) {
            encodedArgs[i] = receiverReason[i + 4];
        }

        innerReason_ = abi.decode(encodedArgs, (bytes));
    }

    function _statusById(bytes32 messageId) internal view returns (SaveInvestCCIPReceiver.StatusCode status) {
        SaveInvestCCIPReceiver.FailedMessage[] memory list = receiver.getFailedMessages(0, 512);
        for (uint256 i; i < list.length; ++i) {
            if (list[i].messageId == messageId) return list[i].statusCode;
        }
        revert("status not found");
    }
}
