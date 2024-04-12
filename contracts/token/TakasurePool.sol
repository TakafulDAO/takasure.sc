//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

import {TakaToken} from "./TakaToken.sol";

contract TakaSurePool {
    TakaToken private immutable takaToken;

    constructor(address takaTokenAddress) {
        takaToken = TakaToken(takaTokenAddress);
    }

    function getTakaTokenAddress() external view returns (address) {
        return address(takaToken);
    }
}
