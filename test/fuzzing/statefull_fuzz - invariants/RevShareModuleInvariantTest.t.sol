// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareModuleHandler} from "test/helpers/handlers/RevShareModuleHandler.sol";

/// @notice Invariants for RevShareModule using a stateful-fuzz handler.
contract RevShareModule_Invariants is StdCheats, StdInvariant, Test {
    TestDeployProtocol deployer;
    HelperConfig helperConfig;
    RevShareModule revShareModule;
    RevShareNFT nft;
    AddressManager addressManager;
    IUSDC usdc;

    address operator; // takadao (OPERATOR & REVENUE_CLAIMER)
    address revenueReceiver; // revenue receiver account from AddressManager
    address randomModule; // authorized Module for notifyNewRevenue

    RevShareModuleHandler handler;

    // Sample pioneer addresses to sanity-check getter gating
    address[] private pioneerSet;

    function setUp() public {
        // Deploy protocol (same pattern as unit tests)
        deployer = new TestDeployProtocol();
        address revShareModuleProxy;
        (, , , , , , revShareModuleProxy, , , , helperConfig) = deployer.run();
        revShareModule = RevShareModule(revShareModuleProxy);

        HelperConfig.NetworkConfig memory cfg = helperConfig.getConfigByChainId(block.chainid);

        // Read AddressManager from storage slot 0 in RevShareModule
        bytes32 amSlot = vm.load(address(revShareModule), bytes32(uint256(0)));
        addressManager = AddressManager(address(uint160(uint256(amSlot))));

        operator = cfg.takadaoOperator;
        revenueReceiver = addressManager.getProtocolAddressByName("REVENUE_RECEIVER").addr;
        usdc = IUSDC(addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

        // Fresh RevShareNFT, then register it
        string memory baseURI = "ipfs://revshare/";
        address nftImpl = address(new RevShareNFT());
        address nftProxy = UnsafeUpgrades.deployUUPSProxy(
            nftImpl,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, address(this)))
        );
        nft = RevShareNFT(nftProxy);

        // Register NFT and a module caller
        randomModule = makeAddr("module");
        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Module);
        addressManager.addProtocolAddress(
            "RANDOM_MODULE",
            randomModule,
            ProtocolAddressType.Module
        );
        vm.stopPrank();

        // --- Seed a wide pioneer base that sums exactly to totalSupply = 1,500 ---
        uint256 remaining = 1500;
        address[] memory seeds = new address[](30);
        for (uint256 i = 0; i < seeds.length; i++) {
            seeds[i] = makeAddr(string(abi.encodePacked("pioneer_", i)));
        }

        vm.startPrank(nft.owner());
        // Give some NFTs to revenueReceiver so 25% stream has a holder
        uint256 rrMint = 20;
        nft.batchMint(revenueReceiver, rrMint);
        pioneerSet.push(revenueReceiver);
        remaining -= rrMint;

        // Distribute to others deterministically
        for (uint256 i = 0; i < seeds.length && remaining > 0; i++) {
            uint256 want = 1 + (uint256(keccak256(abi.encode(i))) % 100); // [1..100]
            if (want > remaining) want = remaining;
            nft.batchMint(seeds[i], want);
            pioneerSet.push(seeds[i]);
            remaining -= want;
        }
        if (remaining > 0) {
            nft.batchMint(seeds[seeds.length - 1], remaining);
            remaining = 0;
        }
        vm.stopPrank();

        require(nft.totalSupply() == 1500, "totalSupply != 1500");

        // Preload balances (no notify in setup)
        deal(address(usdc), address(revShareModule), 1_000_000e6); // module balance
        deal(address(usdc), randomModule, 1_000_000e6); // authorized caller funds

        // Build handler
        handler = new RevShareModuleHandler(
            revShareModule,
            nft,
            usdc,
            addressManager,
            operator,
            revenueReceiver,
            randomModule,
            pioneerSet
        );

        // Register handler actions to fuzz
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = RevShareModuleHandler.op_notify.selector;
        selectors[1] = RevShareModuleHandler.op_claimPioneer.selector;
        selectors[2] = RevShareModuleHandler.op_claimTakadao.selector;
        selectors[3] = RevShareModuleHandler.op_sweep.selector;
        selectors[4] = RevShareModuleHandler.op_setAvailableDate.selector;
        selectors[5] = RevShareModuleHandler.op_release.selector;
        selectors[6] = RevShareModuleHandler.op_setRewardsDuration.selector;
        selectors[7] = RevShareModuleHandler.op_emergency.selector;
        selectors[8] = RevShareModuleHandler.op_warp.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                               INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Module token balance should never be less than approvedDeposits.
    function invariant_BalanceGteApprovedDeposits() public view {
        uint256 bal = usdc.balanceOf(address(revShareModule));
        uint256 approved = revShareModule.approvedDeposits();
        assertGe(bal, approved, "revShareModule under-collateralized vs approvedDeposits");
    }

    /// @notice 75/25 split ratio — small integer drift (carry-over + floor) allowed.
    /// |rP - 3*rT| <= 12 wei/sec.
    function invariant_RateRatioApproximatelyThreeToOne() public view {
        uint256 rp = revShareModule.rewardRatePioneers();
        uint256 rt = revShareModule.rewardRateTakadao();

        if (rp == 0 && rt == 0) return; // no active stream

        uint256 diff = rp > 3 * rt ? rp - 3 * rt : (3 * rt - rp);
        assertLe(diff, 12, "rate ratio must remain ~3:1");
    }

    /// @notice Accumulators are monotone non-decreasing.
    /// Compare computed getters against the handler’s baseline from STORAGE.
    function invariant_AccumulatorsMonotone() public view {
        uint256 p = revShareModule.getRevenuePerNftOwnedByPioneers();
        uint256 t = revShareModule.getRevenuePerNftOwnedByTakadao();
        assertGe(p, handler.lastPerNftP(), "pioneers accumulator decreased");
        assertGe(t, handler.lastPerNftT(), "takadao accumulator decreased");
    }

    /// @notice Getter gating is always enforced.
    function invariant_GetterGating() public view {
        // revenueReceiver must not earn from the pioneers (75%) view
        assertEq(
            revShareModule.earnedByPioneers(revenueReceiver),
            0,
            "RR must not earn from pioneers"
        );

        // A few pioneers must not earn from the takadao (25%) view
        for (uint256 i = 0; i < pioneerSet.length && i < 3; i++) {
            address a = pioneerSet[i];
            if (a == revenueReceiver) continue;
            assertEq(
                revShareModule.earnedByTakadao(a),
                0,
                "pioneer must not earn from takadao view"
            );
        }
    }

    /// @notice Time-related properties.
    function invariant_TimeBounds() public view {
        uint256 lta = revShareModule.lastTimeApplicable();
        uint256 pf = revShareModule.periodFinish();
        uint256 lut = revShareModule.lastUpdateTime();

        assertLe(lta, block.timestamp, "lta must be <= now");
        assertTrue(pf == 0 || lta <= pf, "lta must be <= pf (or pf==0)");
        assertLe(lut, lta, "lastUpdateTime must be <= lastTimeApplicable");
    }

    /// @notice rewardsDuration must remain > 0.
    function invariant_RewardsDurationPositive() public view {
        assertGt(revShareModule.rewardsDuration(), 0, "rewardsDuration must remain > 0");
    }
}
