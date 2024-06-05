const { network } = require("hardhat")
const { developmentChains, isDevnet, isFork, networkConfig } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deployUpgradeProxy } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let daoToken, daoTokenAddress, wakalaClaimAddress

    log("02.01. Deploying TakasurePool Contract...")

    if (isDevnet) {
        usdc = await deployments.get("USDC")
        usdcAddress = usdc.address
    } else {
        usdcAddress = networkConfig[chainId]["usdc"]
    }

    daoToken = await deployments.get("TSToken")
    daoTokenAddress = daoToken.address
    wakalaClaimAddress = networkConfig[chainId]["wakalaClaimAddress"]
    daoOperator = networkConfig[chainId]["daoOperator"]

    const contractName = "TakasurePool"
    const initArgs = [usdcAddress, daoTokenAddress, wakalaClaimAddress, daoOperator]
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
