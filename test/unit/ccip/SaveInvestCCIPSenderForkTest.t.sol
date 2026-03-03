// SPDX-License-Identifier: GNU GPLv3
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SaveInvestCCIPSender} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPSender.sol";
import {CCIPTestERC20, CCIPTestRouter} from "test/mocks/CCIPTestMocks.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {MockV3Aggregator} from "@chainlink/local/src/data-feeds/MockV3Aggregator.sol";

contract SaveInvestCCIPSenderForkTest is Test {
    uint256 private constant SAFE_BLOCK_LAG = 128;
    uint64 private constant DEST_CHAIN_SELECTOR = 4_949_039_107_694_359_620; // Arbitrum One
    uint256 private constant GAS_LIMIT = 1_200_000;
    uint256 private constant SEND_AMOUNT = 125e6; // 125 USDC (6 decimals)
    uint256 private constant DEFAULT_MAX_GAS_LIMIT = 1_200_000;
    uint256 private constant LINK_FEE = 1e18; // 1 LINK
    int256 private constant LINK_USD_PRICE = 20e8; // $20, 8 decimals
    int256 private constant USDC_USD_PRICE = 1e8; // $1, 8 decimals
    string private constant SAVE_VAULT = "PROTOCOL__SF_VAULT";
    string private constant TOO_LONG_PROTOCOL_NAME = "PROTOCOL__ABCDEFGHIJKLMNOPQRSTUVWXYZ_VAULT";

    function testSaveInvestCCIP_sender_sendMessageOnAvaxMainnetFork() public {
        _assertSenderSendMessageFlow("avax_mainnet");
    }

    function testSaveInvestCCIP_sender_sendMessageOnBaseMainnetFork() public {
        _assertSenderSendMessageFlow("base_mainnet");
    }

    function testSaveInvestCCIP_sender_sendMessageOnEthereumMainnetFork() public {
        _assertSenderSendMessageFlow("eth_mainnet");
    }

    function testSaveInvestCCIP_sender_sendMessageOnOptimismMainnetFork() public {
        _assertSenderSendMessageFlow("op_mainnet");
    }

    function testSaveInvestCCIP_sender_initializeRevertsWhenCriticalAddressIsZero() public {
        _createAndSelectPinnedFork("eth_mainnet");

        address implementation = address(new SaveInvestCCIPSender());
        bytes memory initData = abi.encodeWithSelector(
            SaveInvestCCIPSender.initialize.selector,
            address(0),
            address(1),
            address(2),
            address(3),
            DEST_CHAIN_SELECTOR,
            address(this)
        );

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__AddressZeroNotAllowed.selector);
        UnsafeUpgrades.deployUUPSProxy(implementation, initData);
    }

    function testSaveInvestCCIP_sender_setReceiverContractRevertsForNonOwner() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        sender.setReceiverContract(makeAddr("newReceiver"));
    }

    function testSaveInvestCCIP_sender_setReceiverContractRevertsForZeroAddress() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.setReceiverContract(address(0));
    }

    function testSaveInvestCCIP_sender_setSupportedProtocolRevertsForNonOwner() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        sender.setSupportedProtocol(SAVE_VAULT, true);
    }

    function testSaveInvestCCIP_sender_setSupportedProtocolRevertsForEmptyName() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__InvalidProtocolNameLength.selector);
        sender.setSupportedProtocol("", true);
    }

    function testSaveInvestCCIP_sender_setSupportedProtocolRevertsForNameLongerThan32() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__InvalidProtocolNameLength.selector);
        sender.setSupportedProtocol(TOO_LONG_PROTOCOL_NAME, true);
    }

    function testSaveInvestCCIP_sender_setSupportedProtocolUpdatesStateForTrueAndFalse() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();
        string memory protocol = "PROTOCOL__IF_VAULT";

        assertFalse(sender.supportedProtocols(protocol), "should start disabled");

        sender.setSupportedProtocol(protocol, true);
        assertTrue(sender.supportedProtocols(protocol), "should be enabled");

        sender.setSupportedProtocol(protocol, false);
        assertFalse(sender.supportedProtocols(protocol), "should be disabled");
    }

    function testSaveInvestCCIP_sender_setMaxGasLimitUpdatesValue() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        uint256 newMaxGasLimit = 2_000_000;
        sender.setMaxGasLimit(newMaxGasLimit);
        assertEq(sender.maxGasLimit(), newMaxGasLimit, "maxGasLimit should be updated");
    }

    function testSaveInvestCCIP_sender_setMaxGasLimitRevertsWhenOutOfRange() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__GasLimitOutOfRange.selector);
        sender.setMaxGasLimit(20_000);
    }

    function testSaveInvestCCIP_sender_sendMessageRevertsForZeroAmount() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.sendMessage(SAVE_VAULT, 0, GAS_LIMIT);
    }

    function testSaveInvestCCIP_sender_sendMessageRevertsWhenProtocolIsNotSupported() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__UnsupportedProtocol.selector);
        sender.sendMessage("PROTOCOL__IF_VAULT", SEND_AMOUNT, GAS_LIMIT);
    }

    function testSaveInvestCCIP_sender_sendMessageRevertsWhenAmountIsBelowMinimumDeposit() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert();
        sender.sendMessage(SAVE_VAULT, 99e6, GAS_LIMIT);
    }

    function testSaveInvestCCIP_sender_sendMessageRevertsWhenGasLimitExceedsMax() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        uint256 gasLimitTooHigh = sender.maxGasLimit() + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                SaveInvestCCIPSender.SaveInvestCCIPSender__GasLimitTooHigh.selector,
                gasLimitTooHigh,
                sender.maxGasLimit()
            )
        );
        sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, gasLimitTooHigh);
    }

    function testSaveInvestCCIP_sender_sendMessageCannotPullFundsFromAnotherApprovedUser() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender, CCIPTestRouter router,, CCIPTestERC20 usdc) = _deploySenderFixture();
        address user = makeAddr("user");
        address attacker = makeAddr("attacker");

        usdc.mint(user, SEND_AMOUNT);
        vm.prank(user);
        usdc.approve(address(sender), SEND_AMOUNT);

        router.setFee(0);

        vm.prank(attacker);
        vm.expectRevert();
        sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);
    }

    function testSaveInvestCCIP_sender_sendMessageRevertsWhenLinkBalanceIsInsufficient() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender, CCIPTestRouter router,, CCIPTestERC20 usdc) = _deploySenderFixture();

        address user = makeAddr("user");
        usdc.mint(user, SEND_AMOUNT);
        vm.prank(user);
        usdc.approve(address(sender), SEND_AMOUNT);

        router.setFee(10e18);

        _assertRevertSelector(
            address(sender),
            abi.encodeWithSelector(SaveInvestCCIPSender.sendMessage.selector, SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT),
            SaveInvestCCIPSender.SaveInvestCCIPSender__NotEnoughBalance.selector
        );
    }

    function testSaveInvestCCIP_sender_toggleUserPaysCCIPFee() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        assertFalse(sender.isUserPayingCCIPFee(), "should start disabled");
        sender.toggleUserPaysCCIPFee();
        assertTrue(sender.isUserPayingCCIPFee(), "should toggle on");
        sender.toggleUserPaysCCIPFee();
        assertFalse(sender.isUserPayingCCIPFee(), "should toggle off");
    }

    function testSaveInvestCCIP_sender_previewCCIPFeeRevertsWhenFeeInfraIsNotConfigured() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender, CCIPTestRouter router,,) = _deploySenderFixture();
        router.setFee(LINK_FEE);

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__FeePaymentInfraNotConfigured.selector);
        sender.previewCCIPFee(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);
    }

    function testSaveInvestCCIP_sender_previewCCIPFeeReturnsLinkAndUsdcAmounts() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender, CCIPTestRouter router,,) = _deploySenderFixture();
        router.setFee(LINK_FEE);
        _configureFeeInfrastructure(sender);

        (uint256 linkAmount, uint256 usdcAmount) = sender.previewCCIPFee(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);

        assertEq(linkAmount, LINK_FEE, "wrong LINK fee");
        assertEq(usdcAmount, 20e6, "wrong USDC fee quote");
    }

    function testSaveInvestCCIP_sender_sendMessageCollectsUsdcFeeWhenUserPaysModeEnabled() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender, CCIPTestRouter router, CCIPTestERC20 link, CCIPTestERC20 usdc) =
            _deploySenderFixture();
        _configureFeeInfrastructure(sender);
        sender.toggleUserPaysCCIPFee();

        address user = makeAddr("user");
        router.setFee(LINK_FEE);
        link.mint(address(sender), 10e18);

        (, uint256 expectedUsdcFee) = sender.previewCCIPFee(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);

        usdc.mint(user, SEND_AMOUNT + expectedUsdcFee);
        vm.prank(user);
        usdc.approve(address(sender), SEND_AMOUNT + expectedUsdcFee);

        vm.prank(user);
        sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);

        assertEq(router.lastTokenAmount(), SEND_AMOUNT, "bridged amount must remain user transfer amount only");
        assertEq(usdc.balanceOf(address(router)), SEND_AMOUNT, "router should receive only bridged USDC");
        assertEq(usdc.balanceOf(address(sender)), expectedUsdcFee, "sender should retain collected USDC fee");
    }

    function testSaveInvestCCIP_sender_swapAllCollectedUsdcToLinkRevertsWhenFeeSwapPoolIsNotConfigured() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();
        _configureFeeInfrastructure(sender);

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__FeeSwapV4PoolNotConfigured.selector);
        sender.swapAllCollectedUsdcToLink();
    }

    function testSaveInvestCCIP_sender_swapAllCollectedUsdcToLinkRevertsWhenNoCollectedUsdc() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();
        _configureFeeInfrastructure(sender);
        sender.setFeeSwapV4PoolConfig(3000, 60, address(0));

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__NothingToSwap.selector);
        sender.swapAllCollectedUsdcToLink();
    }

    function testSaveInvestCCIP_sender_withdrawLinkRevertsWhenNoBalance() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,,,) = _deploySenderFixture();

        vm.expectRevert(SaveInvestCCIPSender.SaveInvestCCIPSender__NothingToWithdraw.selector);
        sender.withdrawLink(makeAddr("beneficiary"));
    }

    function testSaveInvestCCIP_sender_withdrawLinkTransfersAllBalance() public {
        _createAndSelectPinnedFork("eth_mainnet");
        (SaveInvestCCIPSender sender,, CCIPTestERC20 link,) = _deploySenderFixture();

        address beneficiary = makeAddr("beneficiary");
        link.mint(address(sender), 5e18);

        sender.withdrawLink(beneficiary);

        assertEq(link.balanceOf(address(sender)), 0, "sender LINK balance should be zero");
        assertEq(link.balanceOf(beneficiary), 5e18, "beneficiary should receive LINK");
    }

    function _assertSenderSendMessageFlow(string memory rpcAlias) internal {
        _createAndSelectPinnedFork(rpcAlias);

        (SaveInvestCCIPSender sender, CCIPTestRouter router, CCIPTestERC20 link, CCIPTestERC20 usdc) =
            _deploySenderFixture();

        address user = makeAddr("user");
        router.setFee(1e18);
        link.mint(address(sender), 10e18);
        usdc.mint(user, SEND_AMOUNT);

        vm.prank(user);
        usdc.approve(address(sender), SEND_AMOUNT);

        vm.prank(user);
        bytes32 messageId = sender.sendMessage(SAVE_VAULT, SEND_AMOUNT, GAS_LIMIT);

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

        (string memory protocolName, bytes memory protocolCallData) = abi.decode(router.lastData(), (string, bytes));
        assertEq(protocolName, SAVE_VAULT, "wrong protocol encoded");
        assertEq(
            keccak256(protocolCallData),
            keccak256(abi.encodeWithSignature("deposit(uint256,address)", SEND_AMOUNT, user)),
            "wrong protocol call data encoded"
        );
    }

    function _deploySenderFixture()
        internal
        returns (SaveInvestCCIPSender sender, CCIPTestRouter router, CCIPTestERC20 link, CCIPTestERC20 usdc)
    {
        router = new CCIPTestRouter();
        link = new CCIPTestERC20("Chainlink", "LINK", 18);
        usdc = new CCIPTestERC20("USD Coin", "USDC", 6);

        address implementation = address(new SaveInvestCCIPSender());
        bytes memory initData = abi.encodeWithSelector(
            SaveInvestCCIPSender.initialize.selector,
            address(router),
            address(link),
            address(usdc),
            makeAddr("receiverContract"),
            DEST_CHAIN_SELECTOR,
            address(this)
        );

        sender = SaveInvestCCIPSender(UnsafeUpgrades.deployUUPSProxy(implementation, initData));
        sender.setMaxGasLimit(DEFAULT_MAX_GAS_LIMIT);
        sender.setSupportedProtocol(SAVE_VAULT, true);

        vm.makePersistent(address(router));
        vm.makePersistent(address(link));
        vm.makePersistent(address(usdc));
        vm.makePersistent(address(sender));
    }

    function _configureFeeInfrastructure(SaveInvestCCIPSender sender) internal {
        MockV3Aggregator linkUsdFeed = new MockV3Aggregator(8, LINK_USD_PRICE);
        MockV3Aggregator usdcUsdFeed = new MockV3Aggregator(8, USDC_USD_PRICE);

        // Any non-zero address passes infra checks in tests that don't execute the swap path
        sender.setFeePaymentInfrastructure(makeAddr("universalRouter"), address(linkUsdFeed), address(usdcUsdFeed));
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
