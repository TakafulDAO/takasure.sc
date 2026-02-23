// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TokenPool} from "ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

/// @notice Configures all required CCIP pool lanes for the current local testnet chain.
/// @dev Source testnets configure only Arbitrum Sepolia; Arbitrum Sepolia configures all source testnets.
contract ConfigureCcipPoolLanes is Script, TestnetPoolScriptBase {
    error ConfigureCcipPoolLanes__AddressNotResolved(string label);
    error ConfigureCcipPoolLanes__RemoteTokenMismatchRequiresForceReplace();
    error ConfigureCcipPoolLanes__Uint128Overflow(string key, uint256 value);
    error ConfigureCcipPoolLanes__CallerIsNotPoolOwner(address caller, address owner, address localPool);

    struct ExecutionConfig {
        uint256 localChainId;
        address localPool;
        address localToken;
        bool forceReplace;
        RateLimiter.Config outboundCfg;
        RateLimiter.Config inboundCfg;
    }

    function run() external {
        ExecutionConfig memory cfg;
        cfg.localChainId = block.chainid;
        if (!_isSupportedTestnetChainId(cfg.localChainId)) {
            revert TestnetPoolScriptBase__UnsupportedChainId(cfg.localChainId);
        }

        uint256[] memory remoteChainIds = _remoteChainIdsForLocal(cfg.localChainId);
        cfg.forceReplace = _envBoolOr("CCIP_FORCE_REPLACE_CHAIN_CONFIG", false);

        cfg.localPool = _resolveAddress("CCIP_LOCAL_POOL", cfg.localChainId, _defaultPoolNameForChain(cfg.localChainId));
        cfg.localToken =
            _resolveAddress("CCIP_TESTNET_TOKEN", cfg.localChainId, _defaultTokenNameForChain(cfg.localChainId));

        cfg.outboundCfg =
            _loadRateLimitConfig("CCIP_OUTBOUND_RL_ENABLED", "CCIP_OUTBOUND_RL_CAPACITY", "CCIP_OUTBOUND_RL_RATE");
        cfg.inboundCfg =
            _loadRateLimitConfig("CCIP_INBOUND_RL_ENABLED", "CCIP_INBOUND_RL_CAPACITY", "CCIP_INBOUND_RL_RATE");

        vm.startBroadcast();
        (, address broadcastSender,) = vm.readCallers();
        address localPoolOwner = TokenPool(cfg.localPool).owner();
        console2.log("Broadcast sender:", broadcastSender);
        console2.log("Local pool owner:", localPoolOwner);
        if (broadcastSender != localPoolOwner) {
            revert ConfigureCcipPoolLanes__CallerIsNotPoolOwner(broadcastSender, localPoolOwner, cfg.localPool);
        }

        for (uint256 i; i < remoteChainIds.length; ++i) {
            _configureRemoteLane(cfg, remoteChainIds[i]);
        }
        vm.stopBroadcast();
    }

    function _configureRemoteLane(ExecutionConfig memory cfg, uint256 remoteChainId) internal {
        uint64 remoteSelector = _selectorByChainId(remoteChainId);

        address remotePool = _deploymentAddress(remoteChainId, _defaultPoolNameForChain(remoteChainId));
        address remoteToken = _deploymentAddress(remoteChainId, _defaultTokenNameForChain(remoteChainId));

        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);
        bytes memory remoteTokenAddress = abi.encode(remoteToken);

        _configureLocalPool(
            TokenPool(cfg.localPool),
            remoteSelector,
            remotePoolAddresses,
            remoteTokenAddress,
            cfg.outboundCfg,
            cfg.inboundCfg,
            cfg.forceReplace
        );

        console2.log("Local chainId:", cfg.localChainId);
        console2.log("Remote chainId:", remoteChainId);
        console2.log("Remote selector:", uint256(remoteSelector));
        console2.log("Local pool:", cfg.localPool);
        console2.log("Local token:", cfg.localToken);
        console2.log("Remote pool:", remotePool);
        console2.log("Remote token:", remoteToken);
        console2.log("Force replace:", cfg.forceReplace);
        console2.log("------------------------------------");
    }

    function _remoteChainIdsForLocal(uint256 localChainId) internal pure returns (uint256[] memory remoteChainIds_) {
        if (localChainId == ARB_SEPOLIA_CHAIN_ID) {
            remoteChainIds_ = new uint256[](3);
            remoteChainIds_[0] = BASE_SEPOLIA_CHAIN_ID;
            remoteChainIds_[1] = ETH_SEPOLIA_CHAIN_ID;
            remoteChainIds_[2] = OP_SEPOLIA_CHAIN_ID;
            return remoteChainIds_;
        }

        if (
            localChainId == BASE_SEPOLIA_CHAIN_ID || localChainId == ETH_SEPOLIA_CHAIN_ID
                || localChainId == OP_SEPOLIA_CHAIN_ID
        ) {
            remoteChainIds_ = new uint256[](1);
            remoteChainIds_[0] = ARB_SEPOLIA_CHAIN_ID;
            return remoteChainIds_;
        }

        revert TestnetPoolScriptBase__UnsupportedChainId(localChainId);
    }

    function _configureLocalPool(
        TokenPool localPool,
        uint64 remoteSelector,
        bytes[] memory remotePoolAddresses,
        bytes memory remoteTokenAddress,
        RateLimiter.Config memory outboundCfg,
        RateLimiter.Config memory inboundCfg,
        bool forceReplace
    ) internal {
        bool chainExists = localPool.isSupportedChain(remoteSelector);

        if (!chainExists) {
            _applyChainUpdate(
                localPool, remoteSelector, remotePoolAddresses, remoteTokenAddress, outboundCfg, inboundCfg, false
            );
            console2.log("applyChainUpdates: added new chain config");
            return;
        }

        bytes memory configuredRemoteToken = localPool.getRemoteToken(remoteSelector);
        if (keccak256(configuredRemoteToken) != keccak256(remoteTokenAddress)) {
            if (!forceReplace) revert ConfigureCcipPoolLanes__RemoteTokenMismatchRequiresForceReplace();

            _applyChainUpdate(
                localPool, remoteSelector, remotePoolAddresses, remoteTokenAddress, outboundCfg, inboundCfg, true
            );
            console2.log("applyChainUpdates: replaced existing chain config");
            return;
        }

        localPool.setChainRateLimiterConfig(remoteSelector, outboundCfg, inboundCfg);
        console2.log("setChainRateLimiterConfig: updated");

        if (!localPool.isRemotePool(remoteSelector, remotePoolAddresses[0])) {
            localPool.addRemotePool(remoteSelector, remotePoolAddresses[0]);
            console2.log("addRemotePool: added");
        } else {
            console2.log("addRemotePool: already present");
        }
    }

    function _applyChainUpdate(
        TokenPool localPool,
        uint64 remoteSelector,
        bytes[] memory remotePoolAddresses,
        bytes memory remoteTokenAddress,
        RateLimiter.Config memory outboundCfg,
        RateLimiter.Config memory inboundCfg,
        bool removeFirst
    ) internal {
        uint64[] memory chainsToRemove;
        if (removeFirst) {
            chainsToRemove = new uint64[](1);
            chainsToRemove[0] = remoteSelector;
        } else {
            chainsToRemove = new uint64[](0);
        }

        TokenPool.ChainUpdate[] memory chainUpdates = new TokenPool.ChainUpdate[](1);
        chainUpdates[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteSelector,
            remotePoolAddresses: remotePoolAddresses,
            remoteTokenAddress: remoteTokenAddress,
            outboundRateLimiterConfig: outboundCfg,
            inboundRateLimiterConfig: inboundCfg
        });

        localPool.applyChainUpdates(chainsToRemove, chainUpdates);
    }

    function _resolveAddress(string memory envKey, uint256 chainId, string memory defaultContractName)
        internal
        view
        returns (address resolved_)
    {
        resolved_ = _envAddressOr(envKey, address(0));
        if (resolved_ != address(0)) return resolved_;

        (resolved_,) = _tryDeploymentAddress(chainId, defaultContractName);
        if (resolved_ == address(0)) {
            revert ConfigureCcipPoolLanes__AddressNotResolved(envKey);
        }
    }

    function _loadRateLimitConfig(string memory enabledKey, string memory capacityKey, string memory rateKey)
        internal
        view
        returns (RateLimiter.Config memory cfg_)
    {
        cfg_.isEnabled = _envBoolOr(enabledKey, false);
        uint256 capacity = _envUintOr(capacityKey, 0);
        uint256 rate = _envUintOr(rateKey, 0);

        if (capacity > type(uint128).max) {
            revert ConfigureCcipPoolLanes__Uint128Overflow(capacityKey, capacity);
        }
        if (rate > type(uint128).max) {
            revert ConfigureCcipPoolLanes__Uint128Overflow(rateKey, rate);
        }

        cfg_.capacity = uint128(capacity);
        cfg_.rate = uint128(rate);
    }
}
