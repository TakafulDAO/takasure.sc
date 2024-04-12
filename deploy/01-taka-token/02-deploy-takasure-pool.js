const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("01.02. Deploying TakaSurePool Contract...")

    const takaToken = await deployments.get("TakaToken")

    const contractName = "TakasurePool"
    const args = [takaToken.address]
    const contract = "TakasurePool"
    const takasurePool = await deploySimpleContract(contractName, args, true, contract)
    log("01.02. TakaSurePool Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("01.02. Verifying!... ")
        await verify(takasurePool.address, args)
        log("01.02. Verify process finished! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "takasurePool", "token"]
