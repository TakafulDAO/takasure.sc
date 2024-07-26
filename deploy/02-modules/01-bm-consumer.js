const { network } = require("hardhat")
const { developmentChains, networkConfig } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let functionsRouter, donId, gasLimit, subscriptionId, bmRequester

    log("02.03. Deploying BenefitMultiplierConsumer Contract...")

    functionsRouter = networkConfig[chainId]["functionsRouter"]
    donId = networkConfig[chainId]["donId"]
    gasLimit = networkConfig[chainId]["gasLimit"]
    subscriptionId = networkConfig[chainId]["subscriptionId"]
    bmRequester = networkConfig[chainId]["bmRequester"]

    const contractName = "BenefitMultiplierConsumer"
    const args = [functionsRouter, donId, gasLimit, subscriptionId, bmRequester]
    const deterministicDeployment = false
    const contract = "BenefitMultiplierConsumer"

    const benefitMultiplierConsumer = await deploySimpleContract(
        contractName,
        args,
        deterministicDeployment,
        contract,
    )
    log("02.03. BenefitMultiplierConsumer Contract Deployed! ")

    log("=======================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("02.03. Verifying BenefitMultiplierConsumer Contract!... ")
        await verify(benefitMultiplierConsumer.address, args)
        log("02.03. BenefitMultiplierConsumer Contract Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "bm-consumer"]
