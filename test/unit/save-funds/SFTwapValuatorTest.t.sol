// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {SFTwapValuator} from "contracts/saveFunds/SFTwapValuator.sol";

import {TestERC20} from "test/mocks/TestERC20.sol";
import {MockUniV3Pool} from "test/mocks/MockUniV3Pool.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract SFTwapValuatorTest is Test {
    DeployManagers internal managersDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    SFTwapValuator internal valuator;
    TestERC20 internal token0;
    TestERC20 internal token1;
    MockUniV3Pool internal pool;

    address internal operator;

    uint160 internal constant PRICE_ONE = uint160(1) << 96;
    uint160 internal constant PRICE_FOUR = uint160(1) << 97; // price = 4

    function setUp() public {
        managersDeployer = new DeployManagers();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        operator = operatorAddr;

        token0 = new TestERC20("Token0", "TK0", 18);
        token1 = new TestERC20("Token1", "TK1", 18);
        pool = new MockUniV3Pool(address(token0), address(token1), PRICE_FOUR);

        valuator = new SFTwapValuator(addrMgr, 0);
    }

    function testSFTwapValuator_constructor_RevertsOnZeroAddressManager() public {
        vm.expectRevert(SFTwapValuator.SFTwapValuator__NotAddressZero.selector);
        new SFTwapValuator(AddressManager(address(0)), 0);
    }

    function testSFTwapValuator_setValuationPool_RevertsForNonOperator(address caller) public {
        vm.assume(caller != operator);

        vm.prank(caller);
        vm.expectRevert(SFTwapValuator.SFTwapValuator__NotAuthorizedCaller.selector);
        valuator.setValuationPool(address(token0), address(pool));
    }

    function testSFTwapValuator_setValuationPool_RevertsOnZeroToken() public {
        vm.prank(operator);
        vm.expectRevert(SFTwapValuator.SFTwapValuator__NotAddressZero.selector);
        valuator.setValuationPool(address(0), address(pool));
    }

    function testSFTwapValuator_setValuationPool_RevertsOnZeroPool() public {
        vm.prank(operator);
        vm.expectRevert(SFTwapValuator.SFTwapValuator__InvalidValuationPool.selector);
        valuator.setValuationPool(address(token0), address(0));
    }

    function testSFTwapValuator_setValuationPool_RevertsWhenTokenNotInPool() public {
        TestERC20 other = new TestERC20("Other", "OTH", 18);

        vm.prank(operator);
        vm.expectRevert(SFTwapValuator.SFTwapValuator__InvalidValuationPool.selector);
        valuator.setValuationPool(address(other), address(pool));
    }

    function testSFTwapValuator_setValuationPool_SetsPool() public {
        vm.prank(operator);
        valuator.setValuationPool(address(token0), address(pool));

        assertEq(valuator.valuationPool(address(token0)), address(pool));
    }

    function testSFTwapValuator_setTwapWindow_RevertsWhenTooSmall() public {
        vm.prank(operator);
        vm.expectRevert(SFTwapValuator.SFTwapValuator__InvalidTwapWindow.selector);
        valuator.setTwapWindow(59);
    }

    function testSFTwapValuator_setTwapWindow_Updates() public {
        vm.prank(operator);
        valuator.setTwapWindow(60);

        assertEq(valuator.twapWindow(), 60);
    }

    function testSFTwapValuator_quote_ReturnsAmountForSameToken() public view {
        uint256 amount = 123;
        uint256 quoted = valuator.quote(address(token0), amount, address(token0));
        assertEq(quoted, amount);
    }

    function testSFTwapValuator_quote_ReturnsZeroForZeroAmount() public view {
        uint256 quoted = valuator.quote(address(token0), 0, address(token1));
        assertEq(quoted, 0);
    }

    function testSFTwapValuator_quote_RevertsWhenPoolNotSet() public {
        vm.expectRevert(SFTwapValuator.SFTwapValuator__ValuationPoolNotSet.selector);
        valuator.quote(address(token0), 1, address(token1));
    }

    function testSFTwapValuator_quote_RevertsWhenUnderlyingNotInPool() public {
        vm.prank(operator);
        valuator.setValuationPool(address(token0), address(pool));

        TestERC20 other = new TestERC20("Other", "OTH", 18);

        vm.expectRevert(SFTwapValuator.SFTwapValuator__InvalidValuationPool.selector);
        valuator.quote(address(token0), 10, address(other));
    }

    function testSFTwapValuator_quote_SpotPriceWhenWindowZero() public {
        vm.prank(operator);
        valuator.setValuationPool(address(token0), address(pool));

        uint256 amount = 10;

        uint256 expected = _quoteSpot(address(token0), address(token1), amount);
        uint256 quoted = valuator.quote(address(token0), amount, address(token1));

        assertEq(quoted, expected);
    }

    function testSFTwapValuator_quote_UsesTwapWhenWindowSet() public {
        vm.prank(operator);
        valuator.setValuationPool(address(token0), address(pool));

        pool.setTwapTick(0); // price = 1
        vm.prank(operator);
        valuator.setTwapWindow(60);

        uint256 amount = 10;
        uint256 quoted = valuator.quote(address(token0), amount, address(token1));

        assertEq(quoted, amount);
    }

    function testSFTwapValuator_quote_FallsBackToSpotWhenObserveReverts() public {
        vm.prank(operator);
        valuator.setValuationPool(address(token0), address(pool));

        pool.setObserveRevert(true);
        vm.prank(operator);
        valuator.setTwapWindow(60);

        uint256 amount = 10;
        uint256 expected = _quoteSpot(address(token0), address(token1), amount);
        uint256 quoted = valuator.quote(address(token0), amount, address(token1));

        assertEq(quoted, expected);
    }

    function testSFTwapValuator_quote_Token1ToToken0_UsesInversePrice() public {
        vm.prank(operator);
        valuator.setValuationPool(address(token1), address(pool));

        uint256 amount = 40;
        uint256 expected = _quoteSpot(address(token1), address(token0), amount);
        uint256 quoted = valuator.quote(address(token1), amount, address(token0));

        assertEq(quoted, expected);
    }

    function _quoteSpot(address tokenIn, address tokenOut, uint256 amount) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(address(pool)).slot0();
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 q192 = 1 << 192;

        if (tokenIn == pool.token0() && tokenOut == pool.token1()) {
            return Math.mulDiv(amount, priceX192, q192);
        }

        return Math.mulDiv(amount, q192, priceX192);
    }
}
