const { network } = require("hardhat")
const { developmentChains, networkConfig } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    log("02.03. Deploying FunctionsConsumer Contract...")

    functionsRouter = networkConfig[chainId]["functionsRouter"]

    const contractName = "FunctionsConsumer"
    const args = [functionsRouter]
    const deterministicDeployment = false
    const contract = "FunctionsConsumer"

    const functionsConsumer = await deploySimpleContract(
        contractName,
        args,
        deterministicDeployment,
        contract,
    )
    log("02.03. FunctionsConsumer Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("02.03. Verifying FunctionsConsumer Contract!... ")
        await verify(functionsConsumer.address, args)
        log("02.03. FunctionsConsumer Contract Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["functions-consumer"]
