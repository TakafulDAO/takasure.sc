const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("01.01. Deploying The Life DAO Token Contract...")

    const contractName = "TheLifeDAOToken"
    const args = []
    const deterministicDeployment = false
    const contract = "TheLifeDAOToken"

    const tldToken = await deploySimpleContract(
        contractName,
        args,
        deterministicDeployment,
        contract,
    )
    log("01.01. The Life DAO Token Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("01.01. Verifying The Life DAO Token Contract!... ")
        await verify(tldToken.address, args)
        log("01.02. The Life DAO Token Contract Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "TLD", "token"]
