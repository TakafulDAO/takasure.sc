// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockSFStrategy} from "test/mocks/MockSFStrategy.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {SFVaultHandler} from "test/helpers/handlers/SFVaultHandler.sol";
import {MockValuator} from "test/mocks/MockValuator.sol";

contract SFVaultInvariantTest is StdInvariant, Test {
    SFVault internal vault;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;
    IERC20 internal asset;

    address internal takadao;
    address internal feeRecipient;
    MockValuator internal valuator;

    SFVaultHandler internal handler;

    uint256 internal constant MAX_BPS = 10_000;

    function setUp() public {
        DeployManagers managersDeployer = new DeployManagers();
        DeploySFVault vaultDeployer = new DeploySFVault();
        AddAddressesAndRoles addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());

        // Ensure fee recipient exists (used by takeFees + preview fee branches)
        feeRecipient = makeAddr("feeRecipient");
        MockSFStrategy aggregator = new MockSFStrategy(address(vault), vault.asset());
        valuator = new MockValuator();

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("HELPER__SF_VALUATOR", address(valuator), ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
        vm.stopPrank();

        handler = new SFVaultHandler(vault, asset, addrMgr, takadao);

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mint.selector;
        selectors[2] = handler.redeem.selector;
        selectors[3] = handler.withdraw.selector;

        selectors[4] = handler.tryTransfer.selector;
        selectors[5] = handler.tryTransferFrom.selector;

        selectors[6] = handler.opSetFeeConfig.selector;
        selectors[7] = handler.opSetTVLCap.selector;
        selectors[8] = handler.opTakeFees.selector;
        selectors[9] = handler.opTakeFeesTwiceSameTimestamp.selector;

        selectors[10] = handler.donateToVault.selector;
        selectors[11] = handler.toggleMockFeeRecipientZero.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                                 INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_SFVault_totalAssetsEqualsIdlePlusAggregator() public view {
        assertEq(vault.totalAssets(), vault.idleAssets() + vault.aggregatorAssets());
    }

    function invariant_SFVault_totalSupplyEqualsSumOfActorBalances() public view {
        address[] memory actors = handler.getActors();

        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }

        assertEq(sum, vault.totalSupply());
    }

    function invariant_SFVault_sharesAreNeverTransferable() public view {
        assertTrue(!handler.transferSucceeded());
    }

    function invariant_SFVault_feeConfigStaysInBounds() public view {
        assertTrue(vault.managementFeeBPS() < MAX_BPS);
        assertTrue(vault.performanceFeeBPS() <= MAX_BPS);
        assertTrue(vault.performanceFeeHurdleBPS() <= MAX_BPS);
    }

    function invariant_SFVault_whitelistCapsStayInBounds() public view {
        address underlying = address(asset);
        assertTrue(vault.isTokenWhitelisted(underlying));
        assertTrue(vault.tokenHardCapBPS(underlying) <= MAX_BPS);
    }

    function invariant_SFVault_previewZeroIsZero() public view {
        assertEq(vault.previewDeposit(0), 0);
        assertEq(vault.previewMint(0), 0);
    }
}
