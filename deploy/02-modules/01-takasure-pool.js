const { network } = require("hardhat")
const { developmentChains, isDevnet, isFork, networkConfig } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deployUpgradeProxy } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let takaToken, takaTokenAddress, wakalaClaimAddress

    log("02.01. Deploying TakasurePool Contract...")

    if (isDevnet) {
        usdc = await deployments.get("USDC")
        usdcAddress = usdc.address
    } else {
        usdcAddress = networkConfig[chainId]["usdc"]
    }

    takaToken = await deployments.get("TakaToken")
    takaTokenAddress = takaToken.address
    wakalaClaimAddress = networkConfig[chainId]["wakalaClaimAddress"]

    const contractName = "TakasurePool"
    const initArgs = [usdcAddress, takaTokenAddress, wakalaClaimAddress]
    const proxyPattern = "UUPS"
    const deterministicDeployment = false
    const contract = "TakasurePool"

    const takasurePool = await deployUpgradeProxy(
        contractName,
        initArgs,
        proxyPattern,
        deterministicDeployment,
        contract,
    )

    takasurePoolImplementation = await deployments.get("TakasurePool_Implementation")

    log("02.01. TakasurePool Contract Deployed!")
    log("=====================================================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("02. Verifying TakasurePool!...")
        await verify(takasurePool.address, [])
        log("02. TakasurePool verified!")
        log("=====================================================================================")
        log("02. Verifying TakasurePool implementation!...")
        await verify(takasurePoolImplementation.address, [])
        log("02. TakasurePool implementation verified!")

        log("=====================================================================================")
    }
}

module.exports.tags = ["all", "pool", "takasure"]