// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SaveFundsAutomationRunner} from "scripts/save-funds-interaction/SaveFundsAutomationRunner.sol";

contract DeploySaveFundsAutomationRunner is Script {
    function run() external returns (address saveFundsAutomationRunner) {
        vm.startBroadcast();

        saveFundsAutomationRunner = address(
            new SaveFundsAutomationRunner(
                0xaa0F42417a971642a6eA81134fd47d4B5097b0d6, // Aggregator
                0xdB3177CF90cF7d24cc335C2049AECb96c3B81D8E, // Uni V3 Strategy
                0x51dff4A270295C78CA668c3B6a8b427269AeaA7f, // SFUSDC/SFUSDT Pool
                0x2fE9378AF2f1aeB8b013031d1a3567F6E0d44dA1, // SFUSDC Token
                14_400, // 4 hours
                0x570089AcFD6d07714A7A9aC25A74880e69546656 // Address Manager
            )
        );

        vm.stopBroadcast();

        return (saveFundsAutomationRunner);
    }
}
