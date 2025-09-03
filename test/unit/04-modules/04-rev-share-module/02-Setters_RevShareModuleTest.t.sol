// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ProtocolAddressType, ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract Setters_RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    RevShareModule revShareModule;
    RevShareNFT nft;
    HelperConfig helperConfig;
    IUSDC usdc;
    AddressManager addressManager;

    address takadao;
    address revenueClaimer;
    address revenueReceiver;
    address module = makeAddr("module");
    address revShareModuleAddress;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    event OnAvailableDateSet(uint256 timestamp);
    event OnRewardsDurationSet(uint256 duration);

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , , , , , revShareModuleAddress, , , , helperConfig) = deployer.run();

        revShareModule = RevShareModule(revShareModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;
        revenueClaimer = takadao;

        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftAddress);

        // Read AddressManager from storage slot 0 in RevShareModule
        bytes32 amSlot = vm.load(address(revShareModule), bytes32(uint256(0)));
        addressManager = AddressManager(address(uint160(uint256(amSlot))));

        revenueReceiver = addressManager.getProtocolAddressByName("REVENUE_RECEIVER").addr;
        usdc = IUSDC(addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Module);
        addressManager.addProtocolAddress("RANDOM_MODULE", module, ProtocolAddressType.Module);
        vm.stopPrank();

        vm.prank(nft.owner());
        nft.batchMint(alice, 50);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(nft.owner());
        nft.batchMint(bob, 25);

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);

        vm.prank(nft.owner());
        nft.batchMint(charlie, 84);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        // Start an active stream so mid-stream checks hit
        deal(address(usdc), module, 11_000e6);

        vm.startPrank(module);
        usdc.approve(address(revShareModule), 11_000e6);
        revShareModule.notifyNewRevenue(11_000e6);
        vm.stopPrank();

        // Normalize totalSupply for determinism
        uint256 forcedTotalSupply = 1_500;
        vm.store(address(nft), bytes32(uint256(2)), bytes32(forcedTotalSupply));
    }

    // setAvailableDate: operator-only, future timestamp required, emits event
    function testRevShareModule_setAvailableDateFutureEmitsAndSets() public {
        uint256 newTs = block.timestamp + 10 days;

        vm.prank(takadao);
        vm.expectEmit(false, false, false, true, address(revShareModule));
        emit OnAvailableDateSet(newTs);
        revShareModule.setAvailableDate(newTs);

        assertEq(revShareModule.revenuesAvailableDate(), newTs, "available date not updated");
    }

    // releaseRevenues: operator-only, requires revenuesAvailableDate in the future, emits event
    function testRevShareModule_releaseRevenuesSetsToNowAndEmits() public {
        // Put revenues available date in the future first
        uint256 futureTs = block.timestamp + 30 days;

        vm.prank(takadao);
        revShareModule.setAvailableDate(futureTs);

        uint256 callTime = block.timestamp;
        vm.prank(takadao);
        vm.expectEmit(false, false, false, true, address(revShareModule));
        emit OnAvailableDateSet(callTime);
        revShareModule.releaseRevenues();

        assertEq(revShareModule.revenuesAvailableDate(), callTime, "should set to now");
    }

    function testRevShareModule_setRewardsDurationRevertWhileActiveStream() public {
        // setUp created an active stream → should revert with ActiveStreamOngoing
        vm.expectRevert(RevShareModule.RevShareModule__ActiveStreamOngoing.selector);
        vm.prank(takadao);
        revShareModule.setRewardsDuration(365 days);
    }

    function testRevShareModule_setRewardsDurationAfterFinishSucceedsAndEmits() public {
        // Fast forward to after period finish
        uint256 pf = revShareModule.periodFinish();
        if (pf == 0 || block.timestamp <= pf) {
            _warp((pf == 0 ? 0 : (pf - block.timestamp)) + 1);
        }

        uint256 newDur = 200 days;

        vm.expectEmit(address(revShareModule));
        emit OnRewardsDurationSet(newDur);

        vm.prank(takadao);
        revShareModule.setRewardsDuration(newDur);

        assertEq(revShareModule.rewardsDuration(), newDur, "rewardsDuration not updated");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    function _moduleManager() internal view returns (address) {
        return addressManager.getProtocolAddressByName("MODULE_MANAGER").addr;
    }
}
