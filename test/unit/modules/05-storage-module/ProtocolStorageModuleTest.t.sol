// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {ProtocolStorageModule} from "contracts/modules/ProtocolStorageModule.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";

import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract ProtocolStorageModuleTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    ProtocolStorageModule protocolStorageModule;
    AddressManager addrMgr;
    ModuleManager modMgr;

    address takadao; // operator address (will act as authorized Protocol/Module caller)
    address rando = address(0xBEEF);

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager _addrMgr,
            ModuleManager _modMgr
        ) = managersDeployer.run();

        addrMgr = _addrMgr;
        modMgr = _modMgr;

        (address operatorAddr, , , , , , ) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        (, protocolStorageModule, , ) = moduleDeployer.run(addrMgr);

        takadao = operatorAddr;
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC SET/GET (UINT)
    //////////////////////////////////////////////////////////////*/

    function testProtocolStorageModule_SetUintAndGetUint() public {
        string memory key = "some_random_key";
        uint256 val = 42;
        bytes32 hashed = _hashKey(key);

        vm.startPrank(takadao);
        vm.expectEmit(address(protocolStorageModule));
        // indexed key, value
        emit ProtocolStorageModule.OnUintValueSet(hashed, val);
        protocolStorageModule.setUintValue(key, val);
        vm.stopPrank();

        uint256 got = protocolStorageModule.getUintValue(key);
        assertEq(got, val, "uint round-trip mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                    FEE-SUFFIX GUARD (SUCCESS + REVERT)
    //////////////////////////////////////////////////////////////*/

    function testProtocolStorageModule_SetUint_FeeWithinMax() public {
        string memory key = "platform_fee"; // ends with "_fee"
        uint256 okVal = protocolStorageModule.MAX_FEE(); // boundary OK

        vm.prank(takadao);
        protocolStorageModule.setUintValue(key, okVal);

        assertEq(protocolStorageModule.getUintValue(key), okVal);
    }

    function testProtocolStorageModule_SetUint_FeeOverMaxReverts() public {
        string memory key = "platform_fee"; // ends with "_fee"
        uint256 badVal = protocolStorageModule.MAX_FEE() + 1;
        bytes32 hashed = _hashKey(key);

        bytes memory err = abi.encodeWithSelector(
            ProtocolStorageModule.ProtocolStorageModule__FeeExceedsMaximum.selector,
            hashed,
            badVal,
            protocolStorageModule.MAX_FEE()
        );

        vm.startPrank(takadao);
        vm.expectRevert(err);
        protocolStorageModule.setUintValue(key, badVal);
        vm.stopPrank();
    }

    function testProtocolStorageModule_FeeSuffix_IsCaseSensitive() public {
        // Over max but key DOES NOT end with lowercase "_fee" → should NOT revert
        string memory key = "platform_FEE";
        uint256 badVal = protocolStorageModule.MAX_FEE() + 999;

        vm.prank(takadao);
        protocolStorageModule.setUintValue(key, badVal); // no revert expected

        assertEq(protocolStorageModule.getUintValue(key), badVal);
    }

    function testProtocolStorageModule_FeeSuffix_MustBeAtEnd() public {
        // Contains "_fee" but not at the end → should NOT trigger the cap
        string memory key = "contains_fee_suffix_but_more";
        uint256 badVal = protocolStorageModule.MAX_FEE() + 888;

        vm.prank(takadao);
        protocolStorageModule.setUintValue(key, badVal); // no revert expected

        assertEq(protocolStorageModule.getUintValue(key), badVal);
    }

    /*//////////////////////////////////////////////////////////////
                        OTHER TYPES: SET/GET
    //////////////////////////////////////////////////////////////*/

    function testProtocolStorageModule_SetAndGet_Int_Address_Bool_Bytes32_Bytes() public {
        // int
        string memory ikey = "int_key";
        int256 ival = -123456789;
        vm.prank(takadao);
        protocolStorageModule.setIntValue(ikey, ival);
        assertEq(protocolStorageModule.getIntValue(ikey), ival);

        // address
        string memory akey = "addr_key";
        address aval = address(0x1234);
        vm.prank(takadao);
        protocolStorageModule.setAddressValue(akey, aval);
        assertEq(protocolStorageModule.getAddressValue(akey), aval);

        // bool
        string memory bkey = "bool_key";
        bool bval = true;
        vm.prank(takadao);
        protocolStorageModule.setBoolValue(bkey, bval);
        assertEq(protocolStorageModule.getBoolValue(bkey), bval);

        // bytes32
        string memory k32 = "b32_key";
        bytes32 v32 = keccak256("hello");
        vm.prank(takadao);
        protocolStorageModule.setBytes32Value(k32, v32);
        assertEq(protocolStorageModule.getBytes32Value(k32), v32);

        // bytes
        string memory kb = "bytes_key";
        bytes memory vb = hex"deadbeef00ff";
        vm.prank(takadao);
        protocolStorageModule.setBytesValue(kb, vb);
        bytes memory got = protocolStorageModule.getBytesValue(kb);
        assertEq(keccak256(got), keccak256(vb), "bytes round-trip mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                        2D BYTES32 STORAGE
    //////////////////////////////////////////////////////////////*/

    function testProtocolStorageModule_Bytes32_2D_SetAndGet() public {
        string memory k1 = "parent";
        string memory k2 = "child";
        bytes32 v = bytes32(uint256(123));

        bytes32 h1 = _hashKey(k1);
        bytes32 h2 = _hashKey(k2);

        vm.startPrank(takadao);
        vm.expectEmit(address(protocolStorageModule));
        emit ProtocolStorageModule.OnBytes32Value2DSet(h1, h2, v);
        protocolStorageModule.setBytes32Value2D(k1, k2, v);
        vm.stopPrank();

        bytes32 got = protocolStorageModule.getBytes32Value2D(k1, k2);
        assertEq(got, v, "2D bytes32 round-trip mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                    AUTHZ: ONLY PROTOCOL OR MODULE CALLER
    //////////////////////////////////////////////////////////////*/

    function testProtocolStorageModule_OnlyProtocolOrModule_RevertsForEOA() public {
        vm.startPrank(rando);
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        protocolStorageModule.setUintValue("x", 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _hashKey(string memory k) internal pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }
}
