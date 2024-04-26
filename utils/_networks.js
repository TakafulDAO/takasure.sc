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
        wakalaClaimAddress: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266", // This is hardhat's default account [0]
    },
    42161: {
        name: "mainnet_arbitrum",
        usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // https://developers.circle.com/developer/docs/supported-chains-and-currencies#native-usdc
        wakalaClaimAddress: "0x", // TODO
    },
    421614: {
        name: "testnet_arbitrum_sepolia",
        usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d", // https://developers.circle.com/stablecoins/docs/usdc-on-test-networks
        wakalaClaimAddress: "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1", // This is testnet deployer's account
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
