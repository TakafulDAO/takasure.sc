// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TokenPool} from "ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {TestnetPoolScriptBase} from "deploy/ccip/testnetPool/TestnetPoolScriptBase.s.sol";

/// @notice Configures one local pool -> one remote chain mapping per execution.
/// @dev Re-run for each source chain from Arb Sepolia and for each source chain to Arb Sepolia.
contract ConfigureCcipPoolLanes is Script, TestnetPoolScriptBase {
    error ConfigureCcipPoolLanes__MissingRemoteChainId();
    error ConfigureCcipPoolLanes__SameLocalAndRemoteChain();
    error ConfigureCcipPoolLanes__AddressNotResolved(string label);
    error ConfigureCcipPoolLanes__RemoteTokenMismatchRequiresForceReplace();
    error ConfigureCcipPoolLanes__Uint128Overflow(string key, uint256 value);

    function run() external {
        uint256 localChainId = block.chainid;
        if (!_isSupportedTestnetChainId(localChainId)) {
            revert TestnetPoolScriptBase__UnsupportedChainId(localChainId);
        }

        uint256 remoteChainId = _envUintOr("CCIP_REMOTE_CHAIN_ID", 0);
        if (remoteChainId == 0) revert ConfigureCcipPoolLanes__MissingRemoteChainId();
        if (remoteChainId == localChainId) revert ConfigureCcipPoolLanes__SameLocalAndRemoteChain();
        if (!_isSupportedTestnetChainId(remoteChainId)) {
            revert TestnetPoolScriptBase__UnsupportedChainId(remoteChainId);
        }

        uint64 remoteSelector = _selectorByChainId(remoteChainId);
        bool forceReplace = _envBoolOr("CCIP_FORCE_REPLACE_CHAIN_CONFIG", false);

        address localPool = _resolveAddress("CCIP_LOCAL_POOL", localChainId, _defaultPoolNameForChain(localChainId));
        address localToken = _resolveAddress("CCIP_TESTNET_TOKEN", localChainId, _defaultTokenNameForChain(localChainId));
        address remotePool = _resolveAddress("CCIP_REMOTE_POOL", remoteChainId, _defaultPoolNameForChain(remoteChainId));
        address remoteToken = _resolveAddress("CCIP_REMOTE_TOKEN", remoteChainId, _defaultTokenNameForChain(remoteChainId));

        bytes[] memory remotePoolAddresses = new bytes[](1);
        remotePoolAddresses[0] = abi.encode(remotePool);
        bytes memory remoteTokenAddress = abi.encode(remoteToken);

        RateLimiter.Config memory outboundCfg = _loadRateLimitConfig(
            "CCIP_OUTBOUND_RL_ENABLED", "CCIP_OUTBOUND_RL_CAPACITY", "CCIP_OUTBOUND_RL_RATE"
        );
        RateLimiter.Config memory inboundCfg = _loadRateLimitConfig(
            "CCIP_INBOUND_RL_ENABLED", "CCIP_INBOUND_RL_CAPACITY", "CCIP_INBOUND_RL_RATE"
        );

        vm.startBroadcast();
        _configureLocalPool(
            TokenPool(localPool),
            remoteSelector,
            remotePoolAddresses,
            remoteTokenAddress,
            outboundCfg,
            inboundCfg,
            forceReplace
        );
        vm.stopBroadcast();

        console2.log("Local chainId:", localChainId);
        console2.log("Remote chainId:", remoteChainId);
        console2.log("Remote selector:", uint256(remoteSelector));
        console2.log("Local pool:", localPool);
        console2.log("Local token:", localToken);
        console2.log("Remote pool:", remotePool);
        console2.log("Remote token:", remoteToken);
        console2.log("Force replace:", forceReplace);
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
            _applyChainUpdate(localPool, remoteSelector, remotePoolAddresses, remoteTokenAddress, outboundCfg, inboundCfg, false);
            console2.log("applyChainUpdates: added new chain config");
            return;
        }

        bytes memory configuredRemoteToken = localPool.getRemoteToken(remoteSelector);
        if (keccak256(configuredRemoteToken) != keccak256(remoteTokenAddress)) {
            if (!forceReplace) revert ConfigureCcipPoolLanes__RemoteTokenMismatchRequiresForceReplace();

            _applyChainUpdate(localPool, remoteSelector, remotePoolAddresses, remoteTokenAddress, outboundCfg, inboundCfg, true);
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
