// SPDX-License-Identifier: GNU GPLv3

/// @notice Run only in Arbitrum (One and Sepolia)

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {SaveInvestCCIPReceiver} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPReceiver.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeploySaveInvestCCIPReceiver is Script, DeployConstants, GetContractAddress {
    function run() external returns (SaveInvestCCIPReceiver) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(block.chainid);

        IAddressManager addressManager = IAddressManager(_getContractAddress(chainId, "AddressManager"));
        address usdcAddress;
        if (chainId == ARB_SEPOLIA_CHAIN_ID) usdcAddress = _getContractAddress(chainId, "SFUSDCCcipTestnet");
        else usdcAddress = config.usdc;

        vm.startBroadcast();
        (, address owner,) = vm.readCallers();
        console2.log("SaveInvestCCIPReceiver owner to initialize:");
        console2.logAddress(owner);

        // Deploy SaveInvestCCIPReceiver contract
        SaveInvestCCIPReceiver receiver = new SaveInvestCCIPReceiver(addressManager, config.router, usdcAddress, owner);

        vm.stopBroadcast();

        console2.log("SaveInvestCCIPReceiver deployed at:");
        console2.logAddress(address(receiver));
        console2.log("SaveInvestCCIPReceiver owner:");
        console2.logAddress(owner);

        return (receiver);
    }
}
