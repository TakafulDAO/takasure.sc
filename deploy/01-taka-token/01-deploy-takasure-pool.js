const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("01.01. Deploying TakasurePool Contract...")

    const contractName = "TakasurePool"
    const args = []
    const deterministicDeployment = false
    const contract = "TakasurePool"

    const takasurePool = await deploySimpleContract(
        contractName,
        args,
        deterministicDeployment,
        contract,
    )
    log("01.01. TakaSurePool Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("01.01. Verifying TakaSurePool Contract!... ")
        await verify(takasurePool.address, args)
        log("01.02. TakaSurePool Contract Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "takasurePool", "token"]
