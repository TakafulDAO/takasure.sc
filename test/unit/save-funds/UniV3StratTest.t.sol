// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {SFUniswapV3StrategyLens} from "contracts/saveFunds/SFUniswapV3StrategyLens.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {MockValuator} from "test/mocks/MockValuator.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract UniV3StratTest is Test {
    using SafeERC20 for IERC20;

    DeployManagers internal managersDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3Strategy;
    SFUniswapV3StrategyLens internal uniV3Lens;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    IERC20 internal usdt;

    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");
    MockValuator internal valuator;

    uint256 internal constant MAX_BPS = 10_000;

    // Arbitrum tokens
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    // Uniswap V3 addresses
    address internal constant POOL_USDC_USDT = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;

    int24 internal constant TICK_LOWER = -200;
    int24 internal constant TICK_UPPER = 200;

    function setUp() public {
        // Fork Arbitrum mainnet
        string memory rpcUrl = vm.envString("ARBITRUM_MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        managersDeployer = new DeployManagers();
        aggregatorDeployer = new DeploySFStrategyAggregator();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        // Deploy a UUPS proxy for the vault
        address vaultImplementation = address(new SFVault());
        address vaultAddress = UnsafeUpgrades.deployUUPSProxy(
            vaultImplementation, abi.encodeCall(SFVault.initialize, (addrMgr, IERC20(ARB_USDC), "SF Vault", "SFV"))
        );
        vault = SFVault(vaultAddress);
        asset = IERC20(vault.asset());
        usdt = IERC20(ARB_USDT);

        // Deploy aggregator and set as vault strategy
        aggregator = aggregatorDeployer.run(addrMgr, asset);

        vm.prank(takadao);
        vault.whitelistToken(ARB_USDT);

        // Fee recipient required by SFVault
        feeRecipient = makeAddr("feeRecipient");
        valuator = new MockValuator();
        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("HELPER__SF_VALUATOR", address(valuator), ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // Pause guardian role for pause/unpause coverage
        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        // Deploy Uni V3 strategy (UUPS proxy)
        UniswapV3MathHelper mathHelper = new UniswapV3MathHelper();
        address stratImplementation = address(new SFUniswapV3Strategy());
        address stratProxy = UnsafeUpgrades.deployUUPSProxy(
            stratImplementation,
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    addrMgr,
                    address(vault),
                    IERC20(ARB_USDC),
                    IERC20(ARB_USDT),
                    POOL_USDC_USDT,
                    NONFUNGIBLE_POSITION_MANAGER,
                    address(mathHelper),
                    100_000e6, // max TVL (USDC 6 decimals)
                    UNIVERSAL_ROUTER,
                    TICK_LOWER,
                    TICK_UPPER
                )
            )
        );
        uniV3Strategy = SFUniswapV3Strategy(stratProxy);
        uniV3Lens = new SFUniswapV3StrategyLens();

        // The only strategy in the aggregator
        vm.prank(takadao);
        aggregator.addSubStrategy(address(uniV3Strategy), 10_000);
    }

    function testUniV3Strat_setTwapWindow_RevertsWhenTooSmall() public {
        vm.prank(takadao);
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__InvalidTwapWindow.selector);
        uniV3Strategy.setTwapWindow(59);
    }

    function testUniV3Strat_deposit_RevertsWhenPaused() public {
        vm.prank(pauser);
        uniV3Strategy.pause();

        vm.prank(address(aggregator));
        vm.expectRevert();
        uniV3Strategy.deposit(1, bytes(""));
    }

    function testUniV3Strat_deposit_RevertsWhenZeroAssets() public {
        vm.prank(address(aggregator));
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__NotZeroValue.selector);
        uniV3Strategy.deposit(0, bytes(""));
    }

    function testUniV3Strat_deposit_RevertsWhenMaxTVLReached() public {
        vm.prank(takadao);
        uniV3Strategy.setMaxTVL(100);

        bytes memory v3 = _encodeV3ActionData(0, bytes(""), bytes(""), block.timestamp + 1, 0, 0);

        vm.prank(address(aggregator));
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__MaxTVLReached.selector);
        uniV3Strategy.deposit(101, v3);
    }

    function testUniV3Strat_deposit_RevertsWhenSwapDataMissing() public {
        uint256 assetsToInvest = 1_000e6;
        bytes memory v3 = _encodeV3ActionData(5_000, bytes(""), bytes(""), block.timestamp + 1, 0, 0);

        _fundAggregator(assetsToInvest);
        vm.prank(address(vault));
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__InvalidStrategyData.selector);
        aggregator.deposit(assetsToInvest, _perStrategyData(v3));
    }

    function testUniV3Strat_deposit_MintsPosition_UsesRouterSwap_AndSweeps() public {
        uint256 assetsToInvest = 10_000e6;
        uint16 ratio = 5_000;
        uint256 amountToSwap = (assetsToInvest * ratio) / MAX_BPS;

        bytes memory swapToOther = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, amountToSwap);
        bytes memory v3 = _encodeV3ActionData(ratio, swapToOther, bytes(""), block.timestamp + 1, 0, 0);

        uint256 invested = _depositViaAggregator(assetsToInvest, v3);
        assertGt(invested, 0);

        assertGt(uniV3Strategy.positionTokenId(), 0);

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);
        assertEq(usdt.balanceOf(address(uniV3Strategy)), 0);

        assertGt(uniV3Strategy.totalAssets(), 0);
    }

    function testUniV3Strat_deposit_IncreaseLiquidity_WhenPositionExists() public {
        uint256 assetsToInvest = 5_000e6;
        uint16 ratio = 5_000;

        uint256 swapIn1 = (assetsToInvest * ratio) / MAX_BPS;
        bytes memory swapToOther1 = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, swapIn1);
        bytes memory v3_1 = _encodeV3ActionData(ratio, swapToOther1, bytes(""), block.timestamp + 1, 0, 0);
        _depositViaAggregator(assetsToInvest, v3_1);

        uint256 tokenIdBefore = uniV3Strategy.positionTokenId();
        uint256 totalBefore = uniV3Strategy.totalAssets();

        _approveNFTForStrategy();

        uint256 swapIn2 = (assetsToInvest * ratio) / MAX_BPS;
        bytes memory swapToOther2 = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, swapIn2);
        bytes memory v3_2 = _encodeV3ActionData(ratio, swapToOther2, bytes(""), block.timestamp + 1, 0, 0);
        _depositViaAggregator(assetsToInvest, v3_2);

        assertEq(uniV3Strategy.positionTokenId(), tokenIdBefore);
        assertGt(uniV3Strategy.totalAssets(), totalBefore);

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);
        assertEq(usdt.balanceOf(address(uniV3Strategy)), 0);
    }

    function testUniV3Strat_withdraw_WhenTotalAssetsIsZero_Returns0() public {
        bytes memory v3 = _encodeV3ActionData(0, bytes(""), bytes(""), block.timestamp + 1, 0, 0);

        vm.prank(address(aggregator));
        uint256 withdrawn = uniV3Strategy.withdraw(1e6, address(aggregator), v3);
        assertEq(withdrawn, 0);
    }

    function testUniV3Strat_withdraw_SwapsIdleOtherToUnderlying_AndTransfers() public {
        uint256 idleOther = 2_000e6;
        _fundStrategyOther(idleOther);

        uint256 request = uniV3Strategy.totalAssets();
        assertGt(request, 0);

        bytes memory swapToUnderlying = _encodeSwapDataExactIn(ARB_USDT, ARB_USDC, idleOther);
        bytes memory v3 = _encodeV3ActionData(0, bytes(""), swapToUnderlying, block.timestamp + 1, 0, 0);

        address receiver = makeAddr("receiver");
        uint256 balBefore = asset.balanceOf(receiver);

        vm.prank(address(aggregator));
        uint256 withdrawn = uniV3Strategy.withdraw(request, receiver, v3);

        assertGt(withdrawn, 0);
        assertEq(asset.balanceOf(receiver), balBefore + withdrawn);

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);
        assertEq(usdt.balanceOf(address(uniV3Strategy)), 0);
    }

    function testUniV3Strat_withdraw_FromPosition_DecreasesLiquidity_AndSweeps() public {
        uint256 assetsToInvest = 8_000e6;
        uint16 ratio = 5_000;
        uint256 amountToSwap = (assetsToInvest * ratio) / MAX_BPS;

        bytes memory swapToOther = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, amountToSwap);
        bytes memory v3Deposit = _encodeV3ActionData(ratio, swapToOther, bytes(""), block.timestamp + 1, 0, 0);
        _depositViaAggregator(assetsToInvest, v3Deposit);

        _approveNFTForStrategy();

        address receiver = makeAddr("receiver");
        uint256 receiverBefore = asset.balanceOf(receiver);

        bytes memory v3Withdraw = _encodeV3ActionData(0, bytes(""), bytes(""), block.timestamp + 1, 0, 0);

        vm.prank(address(aggregator));
        uint256 withdrawn = uniV3Strategy.withdraw(1_000e6, receiver, v3Withdraw);

        // Depending on price movement / rounding, the withdrawn underlying may be small.
        assertLe(withdrawn, 1_000e6);
        assertEq(asset.balanceOf(receiver), receiverBefore + withdrawn);

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);
    }

    function testUniV3Strat_harvest_CollectsAndSweeps() public {
        uint256 assetsToInvest = 5_000e6;
        uint16 ratio = 5_000;
        uint256 amountToSwap = (assetsToInvest * ratio) / MAX_BPS;

        bytes memory swapToOther = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, amountToSwap);
        bytes memory v3Deposit = _encodeV3ActionData(ratio, swapToOther, bytes(""), block.timestamp + 1, 0, 0);
        _depositViaAggregator(assetsToInvest, v3Deposit);

        _approveNFTForStrategy();

        vm.prank(takadao);
        aggregator.harvest(bytes(""));

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);
        assertEq(usdt.balanceOf(address(uniV3Strategy)), 0);
    }

    function testUniV3Strat_rebalance_RevertsWithoutVaultApproval() public {
        bytes memory data = abi.encode(int24(-400), int24(400), block.timestamp + 1, uint256(0), uint256(0));

        vm.prank(takadao);
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__VaultNotApprovedForNFT.selector);
        aggregator.rebalance(_perStrategyData(data));
    }

    function testUniV3Strat_rebalance_WhenNoPosition_UpdatesTicks() public {
        _approveNFTForStrategy();

        bytes memory data = abi.encode(int24(-400), int24(400), block.timestamp + 1, uint256(0), uint256(0));

        vm.prank(takadao);
        aggregator.rebalance(_perStrategyData(data));

        (uint8 version,, address poolAddr, int24 tl, int24 tu) =
            abi.decode(uniV3Lens.getPositionDetails(address(uniV3Strategy)), (uint8, uint256, address, int24, int24));

        assertEq(version, 1);
        assertEq(poolAddr, POOL_USDC_USDT);
        assertEq(tl, -400);
        assertEq(tu, 400);
    }

    function testUniV3Strat_rebalance_WithPosition_BurnsOldAndMintsNew() public {
        uint256 assetsToInvest = 7_000e6;
        uint16 ratio = 5_000;
        uint256 amountToSwap = (assetsToInvest * ratio) / MAX_BPS;

        bytes memory swapToOther = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, amountToSwap);
        bytes memory v3Deposit = _encodeV3ActionData(ratio, swapToOther, bytes(""), block.timestamp + 1, 0, 0);
        _depositViaAggregator(assetsToInvest, v3Deposit);

        _approveNFTForStrategy();

        uint256 tokenIdBefore = uniV3Strategy.positionTokenId();
        assertGt(tokenIdBefore, 0);

        bytes memory data = abi.encode(int24(-600), int24(600), block.timestamp + 1, uint256(0), uint256(0));

        vm.prank(takadao);
        aggregator.rebalance(_perStrategyData(data));

        uint256 tokenIdAfter = uniV3Strategy.positionTokenId();
        assertGt(tokenIdAfter, 0);
        assertTrue(tokenIdAfter != tokenIdBefore);

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);

        (,,, int24 tl, int24 tu) =
            abi.decode(uniV3Lens.getPositionDetails(address(uniV3Strategy)), (uint8, uint256, address, int24, int24));
        assertEq(tl, -600);
        assertEq(tu, 600);
    }

    function testUniV3Strat_emergencyExit_RevertsWhenReceiverZero() public {
        vm.prank(takadao);
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__NotZeroValue.selector);
        uniV3Strategy.emergencyExit(address(0));
    }

    function testUniV3Strat_emergencyExit_WithPosition_PausesAndClearsTokenId() public {
        uint256 assetsToInvest = 6_000e6;
        uint16 ratio = 5_000;
        uint256 amountToSwap = (assetsToInvest * ratio) / MAX_BPS;

        bytes memory swapToOther = _encodeSwapDataExactIn(ARB_USDC, ARB_USDT, amountToSwap);
        bytes memory v3Deposit = _encodeV3ActionData(ratio, swapToOther, bytes(""), block.timestamp + 1, 0, 0);
        _depositViaAggregator(assetsToInvest, v3Deposit);

        _approveNFTForStrategy();

        uint256 tokenIdBefore = uniV3Strategy.positionTokenId();
        assertGt(tokenIdBefore, 0);

        address receiver = makeAddr("receiver");

        vm.prank(takadao);
        uniV3Strategy.emergencyExit(receiver);

        assertTrue(uniV3Strategy.paused());
        assertEq(uniV3Strategy.positionTokenId(), 0);

        assertEq(asset.balanceOf(address(uniV3Strategy)), 0);
        assertEq(usdt.balanceOf(address(uniV3Strategy)), 0);
    }

    function testUniV3Strat_views_maxDeposit_maxWithdraw_totalAssets_DoNotRevert() public {
        vm.prank(takadao);
        uniV3Strategy.setTwapWindow(0);

        uniV3Strategy.totalAssets();
        uniV3Strategy.maxWithdraw();

        vm.prank(takadao);
        uniV3Strategy.setTwapWindow(1800);
        uniV3Strategy.totalAssets();

        vm.prank(takadao);
        uniV3Strategy.setTwapWindow(type(uint32).max);
        uniV3Strategy.totalAssets();
    }

    function testUniV3Strat_actionDataValidation_RevertsOnBadRatio_AndBadDeadline() public {
        // Make sure totalAssets() > 0 so withdraw() doesn't early-return before decoding action data.
        _fundStrategyOther(1e6);

        bytes memory badRatio = _encodeV3ActionData(10_001, bytes(""), bytes(""), block.timestamp + 1, 0, 0);
        vm.prank(address(aggregator));
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__InvalidRebalanceParams.selector);
        uniV3Strategy.withdraw(1, address(aggregator), badRatio);

        bytes memory badDeadline = _encodeV3ActionData(0, bytes(""), bytes(""), block.timestamp - 1, 0, 0);
        vm.prank(address(aggregator));
        vm.expectRevert(SFUniswapV3Strategy.SFUniswapV3Strategy__InvalidStrategyData.selector);
        uniV3Strategy.withdraw(1, address(aggregator), badDeadline);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _fundAggregator(uint256 amountUSDC) internal {
        deal(address(asset), address(aggregator), amountUSDC);
    }

    function _fundStrategyOther(uint256 amountUSDT) internal {
        deal(address(usdt), address(uniV3Strategy), amountUSDT);
    }

    function _perStrategyData(bytes memory childData) internal view returns (bytes memory) {
        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](1);
        strategies[0] = address(uniV3Strategy);
        payloads[0] = childData;
        return abi.encode(strategies, payloads);
    }

    function _poolFee() internal view returns (uint24) {
        return IUniswapV3Pool(POOL_USDC_USDT).fee();
    }

    function _path(address tokenIn, address tokenOut) internal view returns (bytes memory) {
        return abi.encodePacked(tokenIn, _poolFee(), tokenOut);
    }

    function _encodeSwapDataExactIn(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        // inputs[0] for Commands.V3_SWAP_EXACT_IN:
        // abi.encode(address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool payerIsUser)
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(uniV3Strategy), amountIn, uint256(0), _path(tokenIn, tokenOut), true);

        uint256 deadline = block.timestamp + 1; // UniversalRouter.execute deadline
        return abi.encode(inputs, deadline);
    }

    function _encodeV3ActionData(
        uint16 otherRatioBPS,
        bytes memory swapToOtherData,
        bytes memory swapToUnderlyingData,
        uint256 pmDeadline,
        uint256 minUnderlying,
        uint256 minOther
    ) internal pure returns (bytes memory) {
        return abi.encode(otherRatioBPS, swapToOtherData, swapToUnderlyingData, pmDeadline, minUnderlying, minOther);
    }

    function _approveNFTForStrategy() internal {
        vm.prank(address(vault));
        IERC721(NONFUNGIBLE_POSITION_MANAGER).setApprovalForAll(address(uniV3Strategy), true);
    }

    function _depositViaAggregator(uint256 amountUSDC, bytes memory v3ActionData) internal returns (uint256 invested) {
        _fundAggregator(amountUSDC);
        vm.prank(address(vault));
        invested = aggregator.deposit(amountUSDC, _perStrategyData(v3ActionData));
    }
}
