// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {MockSFStrategy} from "test/mocks/MockSFStrategy.sol";
import {MockERC721ApprovalForAll} from "test/mocks/MockERC721ApprovalForAll.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract WhitelistVaultTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ONE_USDC = 1e6;

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());

        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    function testSFVault_WhitelistToken_BasicFlow() public {
        address token = makeAddr("tokenA");

        uint256 lenBefore = vault.whitelistedTokensLength();

        vm.prank(takadao);
        vault.whitelistToken(token);

        assertTrue(vault.isTokenWhitelisted(token));
        assertEq(vault.whitelistedTokensLength(), lenBefore + 1);

        address[] memory tokens = vault.getWhitelistedTokens();

        bool found;
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] == token) {
                found = true;
                break;
            }
        }
        assertTrue(found);

        assertEq(vault.tokenHardCapBPS(token), uint16(MAX_BPS));
    }

    function testSFVault_WhitelistToken_RevertsIfZeroToken() public {
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidToken.selector);
        vault.whitelistToken(address(0));
    }

    function testSFVault_WhitelistToken_RevertsIfAlreadyWhitelisted() public {
        address token = makeAddr("tokenA");

        vm.prank(takadao);
        vault.whitelistToken(token);

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__TokenAlreadyWhitelisted.selector);
        vault.whitelistToken(token);
    }

    function testSFVault_WhitelistTokenWithCap_SetsCap() public {
        address token = makeAddr("tokenB");
        uint16 capBPS = 2500;

        vm.prank(takadao);
        vault.whitelistTokenWithCap(token, capBPS);

        assertTrue(vault.isTokenWhitelisted(token));
        assertEq(vault.tokenHardCapBPS(token), capBPS);
    }

    function testSFVault_WhitelistTokenWithCap_RevertsIfInvalidCap() public {
        address token = makeAddr("tokenB");

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidCapBPS.selector);
        vault.whitelistTokenWithCap(token, uint16(MAX_BPS + 1));
    }

    function testSFVault_SetTokenHardCap_UpdatesCap() public {
        address token = makeAddr("tokenC");

        vm.prank(takadao);
        vault.whitelistToken(token);

        vm.prank(takadao);
        vault.setTokenHardCap(token, 1234);

        assertEq(vault.tokenHardCapBPS(token), 1234);
    }

    function testSFVault_SetTokenHardCap_RevertsIfNotWhitelisted() public {
        address token = makeAddr("tokenX");
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__TokenNotWhitelisted.selector);
        vault.setTokenHardCap(token, 1);
    }

    function testSFVault_SetTokenHardCap_RevertsIfInvalidCap() public {
        address token = makeAddr("tokenY");

        vm.prank(takadao);
        vault.whitelistToken(token);

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidCapBPS.selector);
        vault.setTokenHardCap(token, uint16(MAX_BPS + 1));
    }

    function testSFVault_RemoveTokenFromWhitelist_Removes() public {
        address token = makeAddr("tokenD");

        vm.prank(takadao);
        vault.whitelistToken(token);
        assertTrue(vault.isTokenWhitelisted(token));

        vm.prank(takadao);
        vault.removeTokenFromWhitelist(token);

        assertTrue(!vault.isTokenWhitelisted(token));
        assertEq(vault.whitelistedTokensLength(), 1);
    }

    function testSFVault_RemoveTokenFromWhitelist_RevertsIfNotWhitelisted() public {
        address token = makeAddr("tokenZ");

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__TokenNotWhitelisted.selector);
        vault.removeTokenFromWhitelist(token);
    }
}
