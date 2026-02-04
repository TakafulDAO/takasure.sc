// // SPDX-License-Identifier: GPL-3.0

// /*
// * This tests are usually disabled because they require an Anvil fork running.
// * To run them, uncomment this test and run, and then start an Anvil fork with
// * the following command:
// *  anvil --fork-url $ARBITRUM_MAINNET_RPC_URL --fork-block-number 427019000
// * Then, in another terminal, run:
// * forge test --match-contract SaveFundInvariantTest
// */
// pragma solidity 0.8.28;

// import {Test} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
// import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
// import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
// import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
// import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
// import {AddressManager} from "contracts/managers/AddressManager.sol";
// import {ModuleManager} from "contracts/managers/ModuleManager.sol";
// import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
// import {ProtocolAddressType} from "contracts/types/Managers.sol";
// import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
// import {SFVault} from "contracts/saveFunds/SFVault.sol";
// import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
// import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
// import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
// import {SaveFundHandler} from "test/helpers/handlers/SaveFundHandler.sol";
// import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

// contract SaveFundInvariantTest is StdInvariant, Test {
//     string internal constant ANVIL_RPC_URL = "http://127.0.0.1:8545";

//     // ===== Arbitrum One =====
//     address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
//     address internal constant ARB_USDT = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

//     // USDC/USDT 0.01% pool (fee=100) on Uniswap V3 (Arbitrum)
//     address internal constant POOL_USDC_USDT_100 = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;

//     // Uniswap V3 periphery on Arbitrum
//     address internal constant UNIV3_NONFUNGIBLE_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

//     // Universal Router on Arbitrum
//     address internal constant UNI_UNIVERSAL_ROUTER = 0x4C60051384bd2d3C01bfc845Cf5F4b44bcbE9de5;

//     // Strategy tick range (must be multiple of pool tickSpacing; -200/200 is safe for 0.01% pools too)
//     int24 internal constant TICK_LOWER = -200;
//     int24 internal constant TICK_UPPER = 200;

//     // ===== deploy helpers =====
//     DeployManagers internal managersDeployer;
//     AddAddressesAndRoles internal addressesAndRoles;
//     DeploySFStrategyAggregator internal aggregatorDeployer;

//     AddressManager internal addrMgr;
//     ModuleManager internal modMgr;

//     SFVault internal vault;
//     SFStrategyAggregator internal aggregator;
//     SFUniswapV3Strategy internal uniV3;
//     UniswapV3MathHelper internal mathHelper;

//     IERC20 internal usdc = IERC20(ARB_USDC);
//     IERC20 internal usdt = IERC20(ARB_USDT);

//     address internal operator;
//     address internal backendAdmin;
//     address internal keeper;
//     address internal pauseGuardian;
//     address internal feeReceiver;

//     address[] internal users;
//     address[] internal swappers;

//     SaveFundHandler internal handler;

//     function setUp() public {
//         // ===== fork =====
//         uint256 forkId = vm.createFork(ANVIL_RPC_URL);
//         vm.selectFork(forkId);

//         managersDeployer = new DeployManagers();
//         addressesAndRoles = new AddAddressesAndRoles();
//         aggregatorDeployer = new DeploySFStrategyAggregator();

//         (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
//             managersDeployer.run();

//         addrMgr = _addrMgr;
//         modMgr = _modMgr;

//         (operator,,, backendAdmin,,,) = addressesAndRoles.run(addrMgr, config, address(modMgr));

//         keeper = makeAddr("keeper");
//         pauseGuardian = makeAddr("pauseGuardian");
//         feeReceiver = makeAddr("feeReceiver");

//         vm.startPrank(addrMgr.owner());
//         addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
//         addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauseGuardian);
//         addrMgr.createNewRole(Roles.KEEPER);
//         addrMgr.proposeRoleHolder(Roles.KEEPER, keeper);
//         addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeReceiver, ProtocolAddressType.Admin);
//         vm.stopPrank();

//         vm.prank(pauseGuardian);
//         addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

//         vm.prank(keeper);
//         addrMgr.acceptProposedRole(Roles.KEEPER);

//         vault = SFVault(
//             UnsafeUpgrades.deployUUPSProxy(
//                 address(new SFVault()),
//                 abi.encodeCall(SFVault.initialize, (addrMgr, usdc, "Takasure Save Fund Vault", "TSF"))
//             )
//         );

//         aggregator = aggregatorDeployer.run(IAddressManager(address(addrMgr)), usdc, address(vault));

//         vm.startPrank(addrMgr.owner());
//         addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
//         addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
//         vm.stopPrank();

//         // ===== wire vault + whitelist other token =====
//         vm.startPrank(operator);
//         vault.setAggregator(ISFStrategy(address(aggregator)));
//         vault.whitelistToken(address(usdt));
//         vm.stopPrank();

//         // ===== deploy math helper + UniV3 strategy =====
//         mathHelper = new UniswapV3MathHelper();

//         uniV3 = SFUniswapV3Strategy(
//             UnsafeUpgrades.deployUUPSProxy(
//                 address(new SFUniswapV3Strategy()),
//                 abi.encodeCall(
//                     SFUniswapV3Strategy.initialize,
//                     (
//                         addrMgr,
//                         address(vault),
//                         usdc,
//                         usdt,
//                         POOL_USDC_USDT_100,
//                         UNIV3_NONFUNGIBLE_POSITION_MANAGER,
//                         address(mathHelper),
//                         uint256(100_000e6),
//                         UNI_UNIVERSAL_ROUTER,
//                         TICK_LOWER,
//                         TICK_UPPER
//                     )
//                 )
//             )
//         );

//         // ===== add strategy to aggregator =====
//         vm.prank(operator);
//         aggregator.addSubStrategy(address(uniV3), 10_000);

//         // ===== allow strategy to manage V3 position NFTs held by vault =====
//         vm.prank(operator);
//         vault.setERC721ApprovalForAll(UNIV3_NONFUNGIBLE_POSITION_MANAGER, address(uniV3), true);

//         // ===== actors =====
//         _createActorsAndApprovals();

//         // ===== handler =====
//         handler = new SaveFundHandler();
//         handler.configureProtocol(vault, aggregator, uniV3);
//         handler.configureActors(operator, keeper, backendAdmin, pauseGuardian);

//         handler.configureScenario(TICK_LOWER, TICK_UPPER, 100, 100); // dust: 100 units USDC/USDT

//         handler.setUsers(users);
//         handler.setSwappers(swappers);

//         // swappers must approve the MarketSwapCaller inside handler
//         _approveMarketForSwappers();

//         bytes4[] memory selectors = new bytes4[](9);
//         selectors[0] = handler.backend_registerMember.selector;
//         selectors[1] = handler.user_deposit.selector;
//         selectors[2] = handler.user_redeem.selector;
//         selectors[3] = handler.keeper_invest.selector;
//         selectors[4] = handler.keeper_withdrawFromStrategy.selector;
//         selectors[5] = handler.keeper_harvest.selector;
//         selectors[6] = handler.keeper_rebalance.selector;
//         selectors[7] = handler.pauser_togglePause.selector;
//         selectors[8] = handler.attacker_tryTransferFrom.selector;

//         targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
//         targetContract(address(handler));
//     }

//     function invariant_all() public view {
//         _assertTotalSupplyEqualsSumBalances();
//         _assertStrategyCustodyPolicy();
//         _assertNoStaleRouterApprovals();
//     }

//     function _assertTotalSupplyEqualsSumBalances() internal view {
//         uint256 sum;
//         for (uint256 i = 0; i < users.length; i++) {
//             sum += vault.balanceOf(users[i]);
//         }
//         sum += vault.balanceOf(feeReceiver);

//         assertEq(vault.totalSupply(), sum, "share supply mismatch");
//     }

//     function _assertStrategyCustodyPolicy() internal view {
//         // Strategy must not retain *underlying* (USDC). USDT may remain (it is accounted in totalAssets()).
//         assertLe(usdc.balanceOf(address(uniV3)), 100, "uniV3 holds too much USDC");
//     }

//     function _assertNoStaleRouterApprovals() internal view {
//         assertEq(usdc.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDC router allowance not cleared");
//         assertEq(usdt.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDT router allowance not cleared");
//     }

//     function _createActorsAndApprovals() internal {
//         uint256 nUsers = 12;
//         uint256 nSwappers = 8;

//         users = new address[](nUsers);
//         swappers = new address[](nSwappers);

//         for (uint256 i = 0; i < nUsers; i++) {
//             address u = makeAddr(string.concat("user", vm.toString(i)));
//             users[i] = u;

//             // fund user with USDC for deposits
//             deal(ARB_USDC, u, 1_000_000e6);

//             // approve vault spend (USDC)
//             vm.startPrank(u);
//             usdc.approve(address(vault), type(uint256).max);
//             vm.stopPrank();
//         }

//         for (uint256 j = 0; j < nSwappers; j++) {
//             address s = makeAddr(string.concat("swapper", vm.toString(j)));
//             swappers[j] = s;

//             // fund swappers with both sides of the pool
//             deal(ARB_USDC, s, 5_000_000e6);
//             deal(ARB_USDT, s, 5_000_000e6);
//         }
//     }

//     function _approveMarketForSwappers() internal {
//         // MarketSwapCaller pulls via transferFrom(payer), so swappers must approve MarketSwapCaller
//         address market = address(handler.market());
//         for (uint256 i = 0; i < swappers.length; i++) {
//             address s = swappers[i];
//             vm.startPrank(s);
//             usdc.approve(market, type(uint256).max);
//             usdt.approve(market, type(uint256).max);
//             vm.stopPrank();
//         }
//     }
// }
