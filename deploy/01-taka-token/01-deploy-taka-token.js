const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("01.01. Deploying TakaToken Contract...")

    const contractName = "TakaToken"
    const args = []
    const contract = "TakaToken"
    const takaToken = await deploySimpleContract(contractName, args, false, contract)
    log("01.01. TakaToken Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("01.01. Verifying!... ")
        await verify(takaToken.address, args)
        log("01.01. Verify process finished! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "takaToken", "token"]
