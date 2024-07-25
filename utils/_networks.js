const hre = require("hardhat")
require("dotenv").config()

const isFork = process.env.FORK === "true"
const isLocalhost = !isFork && hre.network.name === "localhost"
const isMemnet = hre.network.name === "hardhat"

const isMainnet = hre.network.name.startsWith("mainnet_")
const isTestnet = hre.network.name.startsWith("testnet_")

const isDevnet = isLocalhost || isMemnet
const isRealChain = !isLocalhost && !isMemnet
const isProtocolChain = isMemnet || isFork || isLocalhost || isMainnet || isTestnet

const ARBITRUM_MAINNET_RPC_URL = process.env.ARBITRUM_MAINNET_RPC_URL
const ARBITRUM_TESTNET_SEPOLIA_RPC_URL = process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL

const networkConfig = {
    31337: {
        name: "hardhat",
        // Same as mainnet
        usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // https://developers.circle.com/developer/docs/supported-chains-and-currencies#native-usdc
        feeClaimAddress: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", // This is hardhat's default account [0]
        daoOperator: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", // This is hardhat's default account [1]
    },
    42161: {
        name: "mainnet_arbitrum",
        usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // https://developers.circle.com/developer/docs/supported-chains-and-currencies#native-usdc
        feeClaimAddress: "0x", // TODO
        daoOperator: "0x", // TODO
        rpcUrl: ARBITRUM_MAINNET_RPC_URL,
    },
    421614: {
        name: "testnet_arbitrum_sepolia",
        usdc: "0xf9b2DE65196fA500527c576De9312E3c626C7d6a", // Minimal ERC20 for test purposes
        feeClaimAddress: "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1", // This is testnet deployer's account // Todo: Change later for better tests
        daoOperator: "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1", // This is testnet deployer's account, // Todo: Change later for better tests
        rpcUrl: ARBITRUM_TESTNET_SEPOLIA_RPC_URL,
    },
}

const developmentChains = ["hardhat", "localhost"]
const VERIFICATION_BLOCK_CONFIRMATIONS = 6

module.exports = {
    isFork,
    isLocalhost,
    isMemnet,
    isMainnet,
    isTestnet,
    isDevnet,
    isRealChain,
    isProtocolChain,
    networkConfig,
    developmentChains,
    VERIFICATION_BLOCK_CONFIRMATIONS,
}
