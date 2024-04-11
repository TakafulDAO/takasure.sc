const { network } = require("hardhat")
const { developmentChains } = require("../utils/_networks")
const { verify } = require("../scripts/verify")
const { deploySimpleContract } = require("../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    log("00. Deploying My Contract Contract...")

    const contractName = "MyContract"
    const args = []
    const contract = "MyContract"
    const myContract = await deploySimpleContract(contractName, args, true, contract)
    log("00. My Contract Contract Deployed! ")

    if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
        log("00. Verifying!... ")
        await verify(myContract.address, args)
        log("00. Verify process finished! ")
    }
}

module.exports.tags = ["all", "myContract"]
