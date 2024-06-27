const hre = require("hardhat")

const isFork = process.env.FORK === "true"
const isLocalhost = !isFork && hre.network.name === "localhost"
const isMemnet = hre.network.name === "hardhat"

const isMainnet = hre.network.name.startsWith("mainnet_")
const isTestnet = hre.network.name.startsWith("testnet_")

const isDevnet = isLocalhost || isMemnet
const isRealChain = !isLocalhost && !isMemnet
const isProtocolChain = isMemnet || isFork || isLocalhost || isMainnet || isTestnet

const networkConfig = {
    31337: {
        name: "hardhat",
        // Same as mainnet
        usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // https://developers.circle.com/developer/docs/supported-chains-and-currencies#native-usdc
        wakalaClaimAddress: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", // This is hardhat's default account [0]
        daoOperator: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC", // This is hardhat's default account [1]
    },
    42161: {
        name: "mainnet_arbitrum",
        usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // https://developers.circle.com/developer/docs/supported-chains-and-currencies#native-usdc
        wakalaClaimAddress: "0x", // TODO
        daoOperator: "0x", // TODO
    },
    421614: {
        name: "testnet_arbitrum_sepolia",
        usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", // https://developers.circle.com/stablecoins/docs/usdc-on-test-networks
        wakalaClaimAddress: "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1", // This is testnet deployer's account // Todo: Change later for better tests
        daoOperator: "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1", // This is testnet deployer's account, // Todo: Change later for better tests
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
