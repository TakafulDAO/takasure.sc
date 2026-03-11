// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

// It writes scripts/simulations/revshare_sim.csv (no --broadcast needed).

import {Script, console2} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {IRevShareModule} from "contracts/interfaces/IRevShareModule.sol";
import {IRevShareNFT} from "contracts/interfaces/IRevShareNFT.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract RevShareMonthSimToCsv is Script, StdCheats {
    // ======= Config =======
    string constant OUT = "scripts/simulations/revshare_sim.csv";
    uint256 constant SIM_DAYS = 30;
    uint256 constant ONE_DAY = 1 days;

    // Deposit bounds: 500→1000 USDC in steps of 100
    uint256 constant DEP_MIN = 500e6;
    uint256 constant DEP_MAX = 1000e6;
    uint256 constant DEP_STEP = 100e6;

    // ======= Protocol handles =======
    RevShareModule rev;
    RevShareNFT nft;
    AddressManager am;
    HelperConfig helper;
    IUSDC usdc;

    address takadao; // operator (also revenue claimer in this setup)
    address revenueReceiver; // destination account for Takadao claims
    address module; // authorized caller for notifyNewRevenue

    // ======= Users (Alice..Judy) =======
    address[10] users;
    string[10] names = [
        "Alice",
        "Bob",
        "Charlie",
        "Dave",
        "Eve",
        "Frank",
        "Grace",
        "Heidi",
        "Ivan",
        "Judy"
    ];
    mapping(address => uint256) public minted; // minted NFT count per user
    mapping(address => uint256) public lastClaimDay; // last claim day index (0-based)

    string private csv;

    /*//////////////////////////////////////////////////////////////
                            CSV HELPERS (stack-friendly)
    //////////////////////////////////////////////////////////////*/

    function _csvHeader() internal pure returns (string memory) {
        // Single line header; newline will be added when seeding `csv`
        return
            "day,timestamp,action,actor,amount,rewardRatePioneersScaled,rewardRateTakadaoScaled,periodFinish,revenuePerNftOwnedByPioneers,takadaoRevenueScaled,totalSupply,balanceOfActor,earnedViewBefore,approvedDeposits";
    }

    function _addrToStr(address a) internal pure returns (string memory) {
        return vm.toString(a);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _appendCsvBytes(bytes memory b) internal {
        // Append line + newline to the in-memory buffer
        csv = string.concat(csv, string(b), "\n");
    }

    function _pushCsv(
        uint256 dayIndex,
        string memory action,
        address actor,
        uint256 amount,
        uint256 balanceOfActor,
        uint256 earnedViewBefore
    ) internal {
        // Build the line in small chunks to avoid stack blowups
        bytes memory b;
        b = abi.encodePacked(
            _u(dayIndex),
            ",",
            _u(block.timestamp),
            ",",
            action,
            ",",
            _addrToStr(actor),
            ",",
            _u(amount),
            ","
        );
        b = abi.encodePacked(
            b,
            _u(rev.rewardRatePioneersScaled()),
            ",",
            _u(rev.rewardRateTakadaoScaled()),
            ",",
            _u(rev.periodFinish()),
            ","
        );
        b = abi.encodePacked(
            b,
            _u(rev.getRevenuePerNftOwnedByPioneers()),
            ",",
            _u(rev.getTakadaoRevenueScaled()),
            ",",
            _u(nft.totalSupply()),
            ",",
            _u(balanceOfActor),
            ",",
            _u(earnedViewBefore),
            ",",
            _u(rev.approvedDeposits())
        );
        _appendCsvBytes(b);
    }

    // Deterministic pseudo-random in [DEP_MIN..DEP_MAX] by DEP_STEP
    function _randDeposit(uint256 seed) internal pure returns (uint256) {
        uint256 options = ((DEP_MAX - DEP_MIN) / DEP_STEP) + 1; // 6 options
        uint256 pick = uint256(keccak256(abi.encode(seed))) % options;
        return DEP_MIN + pick * DEP_STEP;
    }

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    function setUpUsers() internal {
        // derive addresses from private keys 1001..1010 for reproducibility
        for (uint256 i = 0; i < 10; i++) {
            users[i] = vm.addr(1001 + i);
            lastClaimDay[users[i]] = 0; // day index when last claimed
        }
    }

    function mintInitialDistribution() internal {
        // Different amounts per user (deterministic, small)
        uint256[10] memory amounts = [uint256(50), 30, 18, 7, 25, 12, 9, 4, 33, 21];
        address owner = nft.owner();
        vm.startPrank(owner);
        for (uint256 i = 0; i < 10; i++) {
            uint256 n = amounts[i];
            minted[users[i]] = n;
            if (n == 1) {
                nft.mint(users[i]);
                _pushCsv(0, "MINT", users[i], n, nft.balanceOf(users[i]), 0);
            } else {
                nft.batchMint(users[i], n);
                _pushCsv(0, "MINT", users[i], n, nft.balanceOf(users[i]), 0);
            }
        }
        vm.stopPrank();

        vm.prank(nft.owner());
        nft.setAddressManager(address(am));
    }

    /*//////////////////////////////////////////////////////////////
                              ACTIONS
    //////////////////////////////////////////////////////////////*/

    function _notifyDaily(uint256 dayIndex, uint256 amount) internal {
        deal(address(usdc), module, amount);
        vm.startPrank(module);
        usdc.approve(address(rev), amount);
        rev.notifyNewRevenue(amount);
        vm.stopPrank();

        _pushCsv(dayIndex, "DEPOSIT", module, amount, 0, 0);
    }

    function _maybeClaimUser(uint256 dayIndex, address user) internal {
        // enforce: at least once every two days
        if (dayIndex >= lastClaimDay[user] + 2) {
            uint256 earnedView = rev.earnedByPioneers(user);
            vm.prank(user);
            uint256 claimed = rev.claimRevenueShare();
            _pushCsv(dayIndex, "CLAIM", user, claimed, nft.balanceOf(user), earnedView);
            lastClaimDay[user] = dayIndex;
        }
    }

    function _maybeClaimTakadao(uint256 dayIndex) internal {
        if (dayIndex % 2 == 0) {
            // every two days
            uint256 earnedView = rev.earnedByTakadao(revenueReceiver);
            vm.prank(takadao); // account holding REVENUE_CLAIMER role
            uint256 claimed = rev.claimRevenueShare();
            _pushCsv(dayIndex, "TAKADAO_CLAIM", revenueReceiver, claimed, 0, earnedView);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                RUN
    //////////////////////////////////////////////////////////////*/

    function run() public {
        // Ensure output dir exists and seed CSV header in memory
        vm.createDir("scripts/simulations", true);
        csv = string.concat(_csvHeader(), "\n");

        TestDeployProtocol deployer = new TestDeployProtocol();
        (, , address _module, , , , address revAddr, , , , HelperConfig _helper) = deployer.run();
        helper = _helper;
        rev = RevShareModule(revAddr);
        module = _module; // authorized to call notifyNewRevenue

        // Fetch AddressManager from storage slot 0
        bytes32 amSlot = vm.load(address(rev), bytes32(uint256(0)));
        am = AddressManager(address(uint160(uint256(amSlot))));

        HelperConfig.NetworkConfig memory cfg = helper.getConfigByChainId(block.chainid);
        takadao = cfg.takadaoOperator;
        revenueReceiver = am.getProtocolAddressByName("REVENUE_RECEIVER").addr;
        usdc = IUSDC(am.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

        // --- 2) Fresh RevShareNFT proxy and register it ---
        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImpl = address(new RevShareNFT());
        address nftProxy = UnsafeUpgrades.deployUUPSProxy(
            nftImpl,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftProxy);

        vm.startPrank(am.owner());
        am.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // --- 3) Set rewards duration to 30 days (operator role required) ---
        vm.prank(takadao);
        rev.setRewardsDuration(30 days);

        // --- 4) Setup users + mint tokens ---
        setUpUsers();
        mintInitialDistribution();

        // --- 5) Simulate for a month ---
        uint256 startTs = block.timestamp;
        for (uint256 day = 1; day <= SIM_DAYS; day++) {
            // move to the next day
            vm.warp(startTs + day * ONE_DAY);
            vm.roll(block.number + 1);

            // daily random deposit
            uint256 dep = _randDeposit(day);
            _notifyDaily(day, dep);

            // ensure each user claims at least every two days
            for (uint256 i = 0; i < users.length; i++) {
                _maybeClaimUser(day, users[i]);
            }

            // Takadao claim (every two days)
            _maybeClaimTakadao(day);
        }

        // Flush CSV once at the end
        vm.writeFile(OUT, csv);
    }
}
