require("dotenv").config()

require("hardhat-deploy")
require("@nomicfoundation/hardhat-ethers")
require("hardhat-deploy-ethers")
require("@nomicfoundation/hardhat-chai-matchers")
require("@nomicfoundation/hardhat-foundry")

/******************************************** Private Keys *********************************************/
const TESTNET_DEPLOYER_PK = process.env.TESTNET_DEPLOYER_PK

/******************************************* RPC providers **********************************************/
const ARBITRUM_MAINNET_RPC_URL = process.env.ARBITRUM_MAINNET_RPC_URL

/***************************************** Config ******************************************************/

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: {
        compilers: [
            {
                version: "0.8.24",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                },
            },
        ],
    },
    defaultNetwork: "hardhat",
    networks: {
        hardhat: {
            forking: {
                //chainId: 42161,
                accounts: [TESTNET_DEPLOYER_PK],
                url: ARBITRUM_MAINNET_RPC_URL,
                blockNumber: 175144195,
                enabled: true,
            },
        },
    },
    namedAccounts: {
        deployer: {
            default: 0,
            localhost: 0,
        },
    },
    mocha: {
        timeout: 300000,
        grep: "@skip-on-ci", // Find everything with this tag
        invert: true, // Run the grep's inverse set.
    },
}
