//SPDX-License-Identifier: GPL-3.0

/**
 * @title OraceConsumer
 * @author Maikel Ordaz
 */

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_3_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

pragma solidity 0.8.25;

contract OracleConsumer is FunctionsClient {}
