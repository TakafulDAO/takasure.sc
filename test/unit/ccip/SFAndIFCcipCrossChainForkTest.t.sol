// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/BurnMintERC677Helper.sol";

import {SFAndIFCcipSender} from "contracts/helpers/chainlink/SFAndIFCcipSender.sol";
import {SFAndIFCcipReceiver} from "contracts/helpers/chainlink/SFAndIFCcipReceiver.sol";
import {Protocols} from "contracts/helpers/chainlink/Protocols.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/Managers.sol";

import {CCIPTestVault} from "test/unit/ccip/CCIPTestMocks.sol";

contract SFAndIFCcipCrossChainForkTest is Test {
    string private constant ETH_SEPOLIA_RPC_ALIAS = "eth_sepolia";
    string private constant ARB_SEPOLIA_RPC_ALIAS = "arb_sepolia";
    string private constant ETH_SEPOLIA_RPC_ENV = "ETHEREUM_TESTNET_SEPOLIA_RPC_URL";
    string private constant ARB_SEPOLIA_RPC_ENV = "ARBITRUM_TESTNET_SEPOLIA_RPC_URL";

    uint256 private constant SEND_AMOUNT = 2e17;
    uint256 private constant GAS_LIMIT = 500_000;

    bool internal isConfigured;

    address internal owner;
    address internal user;

    uint256 internal sourceFork;
    uint256 internal destinationFork;

    Register.NetworkDetails internal sourceNetwork;
    Register.NetworkDetails internal destinationNetwork;

    CCIPLocalSimulatorFork internal ccipLocalSimulatorFork;

    SFAndIFCcipSender internal sender;
    SFAndIFCcipReceiver internal receiver;

    CCIPTestVault internal sfVault;
    CCIPTestVault internal ifVault;
    IAddressManager internal addressManager;

    BurnMintERC677Helper internal sourceToken;
    BurnMintERC677Helper internal destinationToken;

    modifier onlyConfigured() {
        if (!isConfigured) {
            vm.skip(true, "requires ETHEREUM_TESTNET_SEPOLIA_RPC_URL and ARBITRUM_TESTNET_SEPOLIA_RPC_URL");
        }
        _;
    }

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        isConfigured = vm.envExists(ETH_SEPOLIA_RPC_ENV) && vm.envExists(ARB_SEPOLIA_RPC_ENV);
        if (!isConfigured) return;

        sourceFork = vm.createSelectFork(vm.rpcUrl(ETH_SEPOLIA_RPC_ALIAS));
        destinationFork = vm.createFork(vm.rpcUrl(ARB_SEPOLIA_RPC_ALIAS));

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        sourceNetwork = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        sourceToken = BurnMintERC677Helper(sourceNetwork.ccipBnMAddress);

        vm.selectFork(destinationFork);
        destinationNetwork = ccipLocalSimulatorFork.getNetworkDetails(block.chainid);
        destinationToken = BurnMintERC677Helper(destinationNetwork.ccipBnMAddress);

        addressManager = IAddressManager(makeAddr("addressManager"));
        sfVault = new CCIPTestVault(IERC20(address(destinationToken)));
        ifVault = new CCIPTestVault(IERC20(address(destinationToken)));

        receiver = new SFAndIFCcipReceiver(addressManager, destinationNetwork.routerAddress, address(destinationToken));
        _mockProtocolAddress("PROTOCOL__SF_VAULT", address(sfVault));
        _mockProtocolAddress("PROTOCOL__IF_VAULT", address(ifVault));

        vm.selectFork(sourceFork);
        sender = _deploySenderProxy(owner, destinationNetwork.chainSelector, address(receiver));

        vm.selectFork(destinationFork);
        receiver.toggleAllowedSender(sourceNetwork.chainSelector, address(sender));

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.requestLinkFromFaucet(address(sender), 20 ether);
        sourceToken.drip(user);

        vm.prank(user);
        IERC20(address(sourceToken)).approve(address(sender), type(uint256).max);
    }

    function testSFAndIFCcip_crossChain_sendSaveVaultAndReceiveOnDestination() public onlyConfigured {
        uint256 balanceBefore = IERC20(address(sourceToken)).balanceOf(user);

        vm.selectFork(sourceFork);
        bytes32 messageId = sender.sendMessage(Protocols.SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT, user);
        assertNotEq(messageId, bytes32(0), "messageId should not be zero");
        assertEq(IERC20(address(sourceToken)).balanceOf(user), balanceBefore - SEND_AMOUNT, "source user balance mismatch");

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        vm.selectFork(destinationFork);
        assertEq(sfVault.lastCaller(), address(receiver), "vault caller should be receiver");
        assertEq(sfVault.lastReceiver(), user, "vault receiver mismatch");
        assertEq(sfVault.lastAssets(), SEND_AMOUNT, "vault assets mismatch");
        assertEq(IERC20(address(destinationToken)).balanceOf(address(sfVault)), SEND_AMOUNT, "vault token balance mismatch");
    }

    function testSFAndIFCcip_crossChain_sendInvestVaultAndReceiveOnDestination() public onlyConfigured {
        vm.selectFork(sourceFork);
        sender.sendMessage(Protocols.INVEST_VAULT, SEND_AMOUNT, GAS_LIMIT, user);

        vm.selectFork(sourceFork);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(destinationFork);

        vm.selectFork(destinationFork);
        assertEq(ifVault.lastCaller(), address(receiver), "vault caller should be receiver");
        assertEq(ifVault.lastReceiver(), user, "vault receiver mismatch");
        assertEq(ifVault.lastAssets(), SEND_AMOUNT, "vault assets mismatch");
        assertEq(IERC20(address(destinationToken)).balanceOf(address(ifVault)), SEND_AMOUNT, "vault token balance mismatch");
    }

    function _deploySenderProxy(address _owner, uint64 destinationChainSelector, address receiverContract)
        internal
        returns (SFAndIFCcipSender)
    {
        address implementation = address(new SFAndIFCcipSender());
        bytes memory initData = abi.encodeWithSelector(
            SFAndIFCcipSender.initialize.selector,
            sourceNetwork.routerAddress,
            sourceNetwork.linkAddress,
            address(sourceToken),
            receiverContract,
            destinationChainSelector,
            _owner
        );
        return SFAndIFCcipSender(UnsafeUpgrades.deployUUPSProxy(implementation, initData));
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
}
