const { isDevnet, isFork } = require("../../../utils/_networks")
const { deploySimpleContract } = require("../../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    if (isDevnet) {
        log("00.01.01. Deploying USDC mock...")
        const contractName = "USDC"
        const args = []

        const usdc = await deploySimpleContract(contractName)
        log("00.01.01. USDC mock Deployed!...")
        log("==========================================================================")
    }
}

module.exports.tags = ["all", "mocks"]
