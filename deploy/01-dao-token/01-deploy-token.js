const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("01.01. Deploying DAO Token Contract...")

    const contractName = "TSToken"
    const args = []
    const deterministicDeployment = false
    const contract = "TSToken"

    const daoToken = await deploySimpleContract(
        contractName,
        args,
        deterministicDeployment,
        contract,
    )
    log("01.01. DAO Token Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("01.01. Verifying DAO Token Contract!... ")
        await verify(daoToken.address, args)
        log("01.01. DAO Token Contract Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "token", "takasure"]
