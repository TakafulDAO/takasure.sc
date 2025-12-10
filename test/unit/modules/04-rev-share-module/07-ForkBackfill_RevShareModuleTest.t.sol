// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ForkBackfill_RevShareModuleTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    AddressManager addrMgr;
    ModuleManager modMgr;
    RevShareModule revShareModule;
    RevShareNFT nft;
    IUSDC usdc;

    address takadao;
    address revenueReceiver;

    // First two pioneer accounts known to hold RevShare NFTs on Arbitrum mainnet
    address constant PIONEER_1 = 0x00E9cB8f13D610A0e63840169AdEEB636d6aa02B;
    address constant PIONEER_2 = 0x01Ef776BDb788f927980E0193dF74E425f9E3038;

    address constant REVSHARE_NFT_ARB = 0x931eD799F48AaE6908F8Fe204712972f4a64c941;

    uint256 constant FORK_BLOCK_ARB = 409_039_704;

    function setUp() public {
        // Fork Arbitrum mainnet
        string memory rpcUrl = vm.envString("ARBITRUM_MAINNET_RPC_URL");
        uint256 forkId = vm.createFork(rpcUrl, FORK_BLOCK_ARB);
        vm.selectFork(forkId);

        // Deploy managers, modules and roles on the fork
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager addrMgr_, ModuleManager modMgr_) =
            managersDeployer.run();
        addrMgr = addrMgr_;
        modMgr = modMgr_;

        (address operatorAddr,,,,,, address revReceiver) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        takadao = operatorAddr;
        revenueReceiver = revReceiver;

        (,, revShareModule,) = moduleDeployer.run(addrMgr);

        usdc = IUSDC(config.contributionToken);
        nft = RevShareNFT(REVSHARE_NFT_ARB);

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // Backfill pool funding
        uint256 backfillPool = 1_000e6; // 1,000 USDC
        deal(address(usdc), address(revShareModule), backfillPool);
    }

    // Happy path: adminBackfillRevenue assigns correctly and the pioneer can claim
    function testFork_backfillForRealPioneersClaims() public {
        // Sanity
        assertEq(nft.totalSupply(), 1777);
        assertEq(nft.balanceOf(PIONEER_1), 4);
        assertEq(nft.balanceOf(PIONEER_2), 1);

        address[] memory accounts = new address[](2);
        accounts[0] = PIONEER_1;
        accounts[1] = PIONEER_2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6; // 100 USDC
        amounts[1] = 50e6; // 50 USDC

        uint256 approvedDepositsBeforeBackfill = revShareModule.approvedDeposits();
        uint256 pioneer_1_revenueBeforeBackfill = revShareModule.revenuePerAccount(PIONEER_1);
        uint256 pioneer_2_revenueBeforeBackfill = revShareModule.revenuePerAccount(PIONEER_2);

        assertEq(approvedDepositsBeforeBackfill, 0);
        assertEq(pioneer_1_revenueBeforeBackfill, 0);
        assertEq(pioneer_2_revenueBeforeBackfill, 0);

        vm.prank(takadao);
        revShareModule.adminBackfillRevenue(accounts, amounts);

        // Buckets must be updated
        uint256 approvedDepositsAfterBackfill = revShareModule.approvedDeposits();
        uint256 pioneer_1_revenueAfter = revShareModule.revenuePerAccount(PIONEER_1);
        uint256 pioneer_2_revenueAfter = revShareModule.revenuePerAccount(PIONEER_2);

        assertEq(approvedDepositsAfterBackfill, approvedDepositsBeforeBackfill + amounts[0] + amounts[1]);
        assertEq(pioneer_1_revenueAfter, pioneer_1_revenueBeforeBackfill + amounts[0]);
        assertEq(pioneer_2_revenueAfter, pioneer_2_revenueBeforeBackfill + amounts[1]);

        // earnedByPioneers must reflect the backfill, no active streams, has to be == revenuePerAccount
        uint256 earned1 = revShareModule.earnedByPioneers(PIONEER_1);
        uint256 earned2 = revShareModule.earnedByPioneers(PIONEER_2);

        assertEq(earned1, pioneer_1_revenueBeforeBackfill + amounts[0]);
        assertEq(earned2, pioneer_2_revenueBeforeBackfill + amounts[1]);

        // Now pioneers claims
        uint256 pioneer_1_balanceBeforeClaim = usdc.balanceOf(PIONEER_1);
        uint256 pioneer_2_balanceBeforeClaim = usdc.balanceOf(PIONEER_2);

        vm.prank(PIONEER_1);
        uint256 pioneer_1_claimed = revShareModule.claimRevenueShare();

        vm.prank(PIONEER_2);
        uint256 pioneer_2_claimed = revShareModule.claimRevenueShare();

        // claimed amount must be same as backfilled
        assertEq(pioneer_1_claimed, amounts[0]);
        assertEq(pioneer_2_claimed, amounts[1]);

        // USDC received
        assertEq(usdc.balanceOf(PIONEER_1), pioneer_1_balanceBeforeClaim + amounts[0]);
        assertEq(usdc.balanceOf(PIONEER_2), pioneer_2_balanceBeforeClaim + amounts[1]);

        assertEq(revShareModule.revenuePerAccount(PIONEER_1), 0);
        assertEq(revShareModule.revenuePerAccount(PIONEER_2), 0);
    }
}
