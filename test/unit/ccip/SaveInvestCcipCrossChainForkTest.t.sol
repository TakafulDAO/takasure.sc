// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";

import {SaveInvestCCIPSender} from "contracts/helpers/chainlink/SaveInvestCCIPSender.sol";
import {SaveInvestCCIPReceiver} from "contracts/helpers/chainlink/SaveInvestCCIPReceiver.sol";
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

    address private constant ETH_SEPOLIA_SENDER = 0x3D9B60A1AFdEEeA80cd6841B90e14780EF8418DC;
    address private constant ETH_SEPOLIA_SFUSDC = 0xA0224A609051308289f3AEa62fc0019086492A45;
    address private constant ARB_SEPOLIA_RECEIVER = 0x3D616A28649e7023872752aECd9c0d97b3813e38;
    address private constant ARB_SEPOLIA_ADDRESS_MANAGER = 0xAA1b3Fc1f23c1baed05AEc2952A21A0AfCB740F6;
    address private constant ARB_SEPOLIA_SF_VAULT = 0x08037CF86aBbF960DA75ae3eAe9d2Fb8fe312A60;

    uint256 private constant SEND_AMOUNT = 125e6; // 125 SFUSDC (6 decimals)
    uint256 private constant GAS_LIMIT = 500_000;
    string private constant SAVE_VAULT = "PROTOCOL__SF_VAULT";
    string private constant INVEST_VAULT = "PROTOCOL__IF_VAULT";

    address internal user;

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

    function setUp() public {
        user = makeAddr("user");

        sourceFork = vm.createSelectFork(vm.rpcUrl(ETH_SEPOLIA_RPC_ALIAS));
        destinationFork = vm.createFork(vm.rpcUrl(ARB_SEPOLIA_RPC_ALIAS));

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        sourceNetwork = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        vm.selectFork(destinationFork);
        destinationNetwork = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);

        receiver = SaveInvestCCIPReceiver(ARB_SEPOLIA_RECEIVER);
        addressManager = IAddressManager(ARB_SEPOLIA_ADDRESS_MANAGER);
        sfVault = ISFVaultFork(ARB_SEPOLIA_SF_VAULT);

        _ensureSenderAllowedOnReceiver();
        _ensureUserRegisteredInSFVault();

        vm.selectFork(sourceFork);
        sender = SaveInvestCCIPSender(ETH_SEPOLIA_SENDER);
        sourceToken = ISFUSDCCcipTestnet(ETH_SEPOLIA_SFUSDC);

        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sender), 20 ether);
        sourceToken.mintUSDC(user, SEND_AMOUNT * 4);

        vm.prank(user);
        IERC20(address(sourceToken)).approve(address(sender), type(uint256).max);
    }

    function testSaveInvestCCIP_crossChain_sendSaveVaultAndReceiveOnDeployedDestination() public {
        vm.selectFork(destinationFork);
        uint256 depositedBefore = sfVault.userTotalDeposited(user);
        uint256 failedBefore = receiver.getFailedMessageIdsByUser(user).length;

        vm.selectFork(sourceFork);
        uint256 balanceBefore = IERC20(address(sourceToken)).balanceOf(user);

        vm.prank(user);
        bytes32 messageId = sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);
        assertNotEq(messageId, bytes32(0), "messageId should not be zero");
        assertEq(IERC20(address(sourceToken)).balanceOf(user), balanceBefore - SEND_AMOUNT, "source balance mismatch");

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        vm.selectFork(destinationFork);
        uint256 depositedAfter = sfVault.userTotalDeposited(user);
        assertEq(depositedAfter - depositedBefore, SEND_AMOUNT, "vault deposited amount mismatch");
        assertEq(receiver.getFailedMessageIdsByUser(user).length, failedBefore, "save path should not fail");
        assertEq(receiver.userByMessageId(messageId), address(0), "save path should not be tracked as failed");
    }

    function testSaveInvestCCIP_crossChain_sendInvestVaultRevertsDuringRoutingWithoutIFVaultOnDeployedReceiver()
        public
    {
        vm.selectFork(sourceFork);
        vm.prank(user);
        bytes32 messageId = sender.sendMessage(INVEST_VAULT, SEND_AMOUNT, GAS_LIMIT);
        assertNotEq(messageId, bytes32(0), "messageId should not be zero");

        vm.selectFork(sourceFork);
        vm.expectRevert();
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);
    }

    function _ensureSenderAllowedOnReceiver() internal {
        if (receiver.isSenderAllowedByChain(sourceNetwork.chainSelector, ETH_SEPOLIA_SENDER)) return;

        address receiverOwner = receiver.owner();
        vm.prank(receiverOwner);
        receiver.toggleAllowedSender(sourceNetwork.chainSelector, ETH_SEPOLIA_SENDER);
    }

    function _ensureUserRegisteredInSFVault() internal {
        if (sfVault.maxDeposit(user) > 0) return;

        address backendAdmin =
            IAddressManagerRoleReader(address(addressManager)).currentRoleHolders(Roles.BACKEND_ADMIN);
        require(backendAdmin != address(0), "missing BACKEND_ADMIN");

        vm.prank(backendAdmin);
        sfVault.registerMember(user);

        assertGt(sfVault.maxDeposit(user), 0, "user should be registered in SFVault");
    }
}
