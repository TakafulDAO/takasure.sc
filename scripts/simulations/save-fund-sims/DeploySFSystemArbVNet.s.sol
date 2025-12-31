// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

interface IUniV3PoolLike {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function tickSpacing() external view returns (int24);
}

contract DeploySFSystemArbVNet is Script {
    // Default Arbitrum One addresses
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant UNI_V3_POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant UNI_ARBITRUM_UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address constant UNI_ARB_WETH_USDC_005_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // WETH/USDC 0.05% pool on Arbitrum
    uint256 constant VAULT_TVL_CAP = 0; // 0 = unlimited; SFVault default is 20k USDC
    uint256 constant STRAT_MAX_TVL = 0; // 0 = unlimited
    int24 constant HALF_RANGE_TICKS = 1200;

    struct Deployed {
        AddressManager am;
        SFVault vault;
        SFStrategyAggregator agg;
        SFUniswapV3Strategy uni;
    }

    function run() external returns (Deployed memory d) {
        address deployer = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;

        vm.startBroadcast();

        // --- deploy AddressManager (UUPS proxy) ---
        AddressManager am = AddressManager(
            Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (deployer)))
        );

        // --- deploy SFVault (UUPS proxy) ---
        SFVault vault = SFVault(
            Upgrades.deployUUPSProxy(
                "SFVault.sol",
                abi.encodeCall(
                    SFVault.initialize, (IAddressManager(address(am)), IERC20(ARB_USDC), "Save Funds Vault", "sfUSDC")
                )
            )
        );

        // --- deploy SFStrategyAggregator (UUPS proxy) ---
        SFStrategyAggregator agg = SFStrategyAggregator(
            Upgrades.deployUUPSProxy(
                "SFStrategyAggregator.sol",
                abi.encodeCall(
                    SFStrategyAggregator.initialize, (IAddressManager(address(am)), IERC20(ARB_USDC), address(vault))
                )
            )
        );

        // --- register protocol addresses required by onlyContract() modifiers + fee receiver ---
        am.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        am.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(agg), ProtocolAddressType.Protocol);
        am.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", deployer, ProtocolAddressType.Admin);

        // --- create + assign roles ---
        _createAndAssignRole(am, Roles.OPERATOR, deployer);
        _createAndAssignRole(am, Roles.KEEPER, deployer);
        _createAndAssignRole(am, Roles.BACKEND_ADMIN, deployer);
        _createAndAssignRole(am, Roles.PAUSE_GUARDIAN, deployer);

        vault.setTVLCap(VAULT_TVL_CAP);

        // SFUniswapV3Strategy.initialize() requires BOTH tokens whitelisted in vault
        // USDC is whitelisted by default in SFVault.initialize; we must whitelist WETH.
        vault.whitelistTokenWithCap(ARB_WETH, 10_000);

        // set the aggregator on the vault
        vault.setAggregator(ISFStrategy(address(agg)));

        // --- compute ticks for strategy ---
        (int24 tickLower, int24 tickUpper) = _computeRange();

        // --- deploy Uniswap strategy (UUPS proxy) ---
        SFUniswapV3Strategy uni = SFUniswapV3Strategy(
            Upgrades.deployUUPSProxy(
                "SFUniswapV3Strategy.sol",
                abi.encodeCall(
                    SFUniswapV3Strategy.initialize,
                    (
                        IAddressManager(address(am)),
                        address(vault),
                        IERC20(ARB_USDC),
                        IERC20(ARB_WETH),
                        UNI_ARB_WETH_USDC_005_POOL,
                        UNI_V3_POSITION_MANAGER,
                        address(new UniswapV3MathHelper()),
                        STRAT_MAX_TVL,
                        UNI_ARBITRUM_UNIVERSAL_ROUTER,
                        tickLower,
                        tickUpper
                    )
                )
            )
        );

        // allow strategy to manage vault-owned Uniswap V3 position NFTs
        vault.setERC721ApprovalForAll(UNI_V3_POSITION_MANAGER, address(uni), true);

        // configure aggregator to allocate 100% to this one strategy
        address[] memory strategies = new address[](1);
        uint16[] memory weights = new uint16[](1);
        bool[] memory actives = new bool[](1);

        strategies[0] = address(uni);
        weights[0] = 10_000;
        actives[0] = true;

        agg.setConfig(abi.encode(strategies, weights, actives));

        vm.stopBroadcast();

        console2.log("AddressManager:", address(am));
        console2.log("SFVault:", address(vault));
        console2.log("Aggregator:", address(agg));
        console2.log("UniswapV3Strategy:", address(uni));

        d = Deployed({am: am, vault: vault, agg: agg, uni: uni});
    }

    function _createAndAssignRole(AddressManager _am, bytes32 _role, address _roleHolder) internal {
        // Owner creates role + proposes holder
        _am.createNewRole(_role);
        _am.proposeRoleHolder(_role, _roleHolder);

        _am.acceptProposedRole(_role);
    }

    function _computeRange() internal view returns (int24 lower_, int24 upper_) {
        (, int24 _tick,,,,,) = IUniV3PoolLike(UNI_ARB_WETH_USDC_005_POOL).slot0();
        int24 _spacing = IUniV3PoolLike(UNI_ARB_WETH_USDC_005_POOL).tickSpacing();

        lower_ = _floorToSpacing(_tick - HALF_RANGE_TICKS, _spacing);
        upper_ = _floorToSpacing(_tick + HALF_RANGE_TICKS, _spacing);

        // ensure valid
        if (upper_ <= lower_) upper_ = lower_ + _spacing;
    }

    function _floorToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 _compressed = _tick / _spacing;
        if (_tick < 0 && (_tick % _spacing != 0)) _compressed -= 1;
        return _compressed * _spacing;
    }
}
