// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {ModuleState} from "contracts/types/States.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract Setters_RevShareModuleTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    AddressManager addressManager;
    RevShareModule revShareModule;
    RevShareNFT nft;

    IUSDC usdc;
    address takadao;
    address revenueClaimer;
    address revenueReceiver;
    address module;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    event OnAvailableDateSet(uint256 timestamp);
    event OnRewardsDurationSet(uint256 duration);

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager addrMgr, ModuleManager modMgr) =
            managersDeployer.run();

        (address operatorAddr,,,,,, address revReceiver) = addressesAndRoles.run(addrMgr, config, address(modMgr));

        SubscriptionModule subscriptions;
        (,, revShareModule, subscriptions) = moduleDeployer.run(addrMgr);

        module = address(subscriptions);

        takadao = operatorAddr;
        revenueClaimer = takadao;

        // Fresh RevShareNFT proxy
        string memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation, abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftAddress);

        revenueReceiver = revReceiver;
        usdc = IUSDC(config.contributionToken);

        addressManager = addrMgr;

        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Protocol);
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
