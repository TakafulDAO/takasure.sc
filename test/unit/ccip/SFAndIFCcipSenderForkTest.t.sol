// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SFAndIFCcipSender} from "contracts/helpers/chainlink/SFAndIFCcipSender.sol";
import {Protocols} from "contracts/helpers/chainlink/Protocols.sol";
import {CCIPTestERC20, CCIPTestRouter} from "test/unit/ccip/CCIPTestMocks.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract SFAndIFCcipSenderForkTest is Test {
    uint256 private constant SAFE_BLOCK_LAG = 128;
    uint64 private constant DEST_CHAIN_SELECTOR = 4_949_039_107_694_359_620; // Arbitrum One
    uint256 private constant GAS_LIMIT = 300_000;
    uint256 private constant SEND_AMOUNT = 25e6; // 25 USDC (6 decimals)

    function testSFAndIFCcip_sender_sendMessageOnAvaxMainnetFork() public {
        _assertSenderSendMessageFlow("avax_mainnet");
    }

    function testSFAndIFCcip_sender_sendMessageOnBaseMainnetFork() public {
        _assertSenderSendMessageFlow("base_mainnet");
    }

    function testSFAndIFCcip_sender_sendMessageOnEthereumMainnetFork() public {
        _assertSenderSendMessageFlow("eth_mainnet");
    }

    function testSFAndIFCcip_sender_sendMessageOnOptimismMainnetFork() public {
        _assertSenderSendMessageFlow("op_mainnet");
    }

    function testSFAndIFCcip_sender_initializeRevertsWhenCriticalAddressIsZero() public {
        _createAndSelectPinnedFork("eth_mainnet");

        address implementation = address(new SFAndIFCcipSender());
        bytes memory initData = abi.encodeWithSelector(
            SFAndIFCcipSender.initialize.selector,
            address(0),
            address(1),
            address(2),
            address(3),
            DEST_CHAIN_SELECTOR,
            address(this)
        );

        vm.expectRevert(SFAndIFCcipSender.SFAndIFCcipSender__AddressZeroNotAllowed.selector);
        UnsafeUpgrades.deployUUPSProxy(implementation, initData);
    }

    function testSFAndIFCcip_sender_setReceiverContractRevertsForNonOwner() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,,,) = _deploySenderFixture();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        sender.setReceiverContract(makeAddr("newReceiver"));
    }

    function testSFAndIFCcip_sender_setReceiverContractRevertsForZeroAddress() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.setReceiverContract(address(0));
    }

    function testSFAndIFCcip_sender_sendMessageRevertsForInvalidProtocol() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.sendMessage(3, SEND_AMOUNT, GAS_LIMIT, makeAddr("user"));
    }

    function testSFAndIFCcip_sender_sendMessageRevertsForZeroAmount() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.sendMessage(Protocols.SAVE_VAULT, 0, GAS_LIMIT, makeAddr("user"));
    }

    function testSFAndIFCcip_sender_sendMessageRevertsForZeroUserAddress() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.sendMessage(Protocols.SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT, address(0));
    }

    function testSFAndIFCcip_sender_sendMessageRevertsWhenLinkBalanceIsInsufficient() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender, CCIPTestRouter router,, CCIPTestERC20 usdc) = _deploySenderFixture();

        address user = makeAddr("user");
        usdc.mint(user, SEND_AMOUNT);
        vm.prank(user);
        usdc.approve(address(sender), SEND_AMOUNT);

        router.setFee(10e18);

        _assertRevertSelector(
            address(sender),
            abi.encodeWithSelector(
                SFAndIFCcipSender.sendMessage.selector, Protocols.SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT, user
            ),
            SFAndIFCcipSender.SFAndIFCcipSender__NotEnoughBalance.selector
        );
    }

    function testSFAndIFCcip_sender_withdrawLinkRevertsWhenNoBalance() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,,,) = _deploySenderFixture();

        vm.expectRevert(SFAndIFCcipSender.SFAndIFCcipSender__NothingToWithdraw.selector);
        sender.withdrawLink(makeAddr("beneficiary"));
    }

    function testSFAndIFCcip_sender_withdrawLinkTransfersAllBalance() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SFAndIFCcipSender sender,, CCIPTestERC20 link,) = _deploySenderFixture();

        address beneficiary = makeAddr("beneficiary");
        link.mint(address(sender), 5e18);

        sender.withdrawLink(beneficiary);

        assertEq(link.balanceOf(address(sender)), 0, "sender LINK balance should be zero");
        assertEq(link.balanceOf(beneficiary), 5e18, "beneficiary should receive LINK");
    }

    function _assertSenderSendMessageFlow(string memory rpcAlias) internal {
        _createAndSelectPinnedFork(rpcAlias);

        (SFAndIFCcipSender sender, CCIPTestRouter router, CCIPTestERC20 link, CCIPTestERC20 usdc) =
            _deploySenderFixture();

        address user = makeAddr("user");
        router.setFee(1e18);
        link.mint(address(sender), 10e18);
        usdc.mint(user, SEND_AMOUNT);

        vm.prank(user);
        usdc.approve(address(sender), SEND_AMOUNT);

        bytes32 messageId = sender.sendMessage(Protocols.SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT, user);

        assertEq(messageId, bytes32(uint256(1)), "unexpected messageId");
        assertEq(router.lastDestinationChainSelector(), DEST_CHAIN_SELECTOR, "wrong destination selector");
        assertEq(router.lastCaller(), address(sender), "router caller should be sender");
        assertEq(router.lastFeeToken(), address(link), "wrong fee token");
        assertEq(router.lastToken(), address(usdc), "wrong token bridged");
        assertEq(router.lastTokenAmount(), SEND_AMOUNT, "wrong token bridged amount");

        assertEq(link.allowance(address(sender), address(router)), 0, "LINK allowance must be reset");
        assertEq(usdc.allowance(address(sender), address(router)), 0, "USDC allowance must be reset");

        assertEq(link.balanceOf(address(router)), 1e18, "router should receive LINK fee");
        assertEq(usdc.balanceOf(address(router)), SEND_AMOUNT, "router should receive bridged USDC");

        (uint256 protocolToCall, bytes memory protocolCallData) = abi.decode(router.lastData(), (uint256, bytes));
        assertEq(protocolToCall, Protocols.SAVE_VAULT, "wrong protocol encoded");
        assertEq(
            keccak256(protocolCallData),
            keccak256(abi.encodeWithSignature("deposit(uint256,address)", SEND_AMOUNT, user)),
            "wrong protocol call data encoded"
        );
    }

    function _deploySenderFixture()
        internal
        returns (SFAndIFCcipSender sender, CCIPTestRouter router, CCIPTestERC20 link, CCIPTestERC20 usdc)
    {
        router = new CCIPTestRouter();
        link = new CCIPTestERC20("Chainlink", "LINK", 18);
        usdc = new CCIPTestERC20("USD Coin", "USDC", 6);

        address implementation = address(new SFAndIFCcipSender());
        bytes memory initData = abi.encodeWithSelector(
            SFAndIFCcipSender.initialize.selector,
            address(router),
            address(link),
            address(usdc),
            makeAddr("receiverContract"),
            DEST_CHAIN_SELECTOR,
            address(this)
        );

        sender = SFAndIFCcipSender(UnsafeUpgrades.deployUUPSProxy(implementation, initData));

        vm.makePersistent(address(router));
        vm.makePersistent(address(link));
        vm.makePersistent(address(usdc));
        vm.makePersistent(address(sender));
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

    function _assertRevertSelector(address target, bytes memory callData, bytes4 expectedSelector) internal {
        (bool success, bytes memory returnData) = target.call(callData);
        assertFalse(success, "expected call to revert");
        assertGe(returnData.length, 4, "missing revert selector");

        bytes4 returnedSelector;
        assembly {
            returnedSelector := mload(add(returnData, 0x20))
        }

        assertEq(returnedSelector, expectedSelector, "unexpected revert selector");
    }
}
