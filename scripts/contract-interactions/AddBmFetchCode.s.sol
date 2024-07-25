// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {BmFetcher} from "contracts/takasure/oracle/BmFetcher.sol";

contract AddBmFetchCode is Script {
    address bmFetcherContracctAddress = 0xE18D8736Db905f21debf8D7E9800D517c804E749;
    BmFetcher bmFetcher = BmFetcher(bmFetcherContracctAddress);
    string newSourceCode =
        'const userAddress = args[0] // make HTTP request const url = `http://34.228.189.184:5559/api/v1/user/bm` console.log(`HTTP GET Request to ${url}?fsyms=${userAddress}`) const bmRequest = Functions.makeHttpRequest({ url: url, method: "GET", params: { WalletAddr: userAddress, }, }) console.log("Request sent to BM API") console.log("Waiting for response...") // Execute the API request (Promise) const bmResponse = await bmRequest if (bmResponse.error) { return Functions.encodeUint256(0) } const data = bmResponse["data"] if (data.Response === "Error") { console.error(data.Message) throw Error(`Functional error. Read message: ${data.Message}`) } const bm = data["BenefitMultiplier"] console.log(`${userAddress} bm is: ${bm}`) return Functions.encodeUint256(bm)';

    function run() public {
        vm.startBroadcast();
        bmFetcher.setBMSourceRequestCode(newSourceCode);
        vm.stopBroadcast();
    }
}
