const { network, ethers, upgrades } = require("hardhat")
const { networkConfig } = require("../../utils/_networks")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    log("02.03. Deploying FunctionsConsumer Contract...")

    functionsRouter = networkConfig[chainId]["functionsRouter"]
    donId = networkConfig[chainId]["donId"]
    subscriptionId = networkConfig[chainId]["subscriptionId"]
    sourceCode = networkConfig[chainId]["sourceCode"]

    const initArgs = [functionsRouter, donId, subscriptionId, sourceCode]

    const FunctionsConsumer = await ethers.getContractFactory("FunctionsConsumer")
    const functionsConsumer = await upgrades.deployProxy(FunctionsConsumer, initArgs)
    await functionsConsumer.waitForDeployment()

    functionsConsumerAddress = await functionsConsumer.getAddress()
    const artifact = await deployments.getArtifact("FunctionsConsumer")

    log("02.03. Writing FunctionsConsumer Contract Deployment Data...")

    deployments.save("FunctionsConsumer", {
        abi: artifact.abi,
        address: functionsConsumerAddress,
        bytecode: artifact.bytecode,
        deployedBytecode: artifact.deployedBytecode,
    })

    log("02.03. FunctionsConsumer Data stored in the deployments folder")

    log("02.03. FunctionsConsumer Contract Deployed!")
    log("=====================================================================================")
}

module.exports.tags = ["all", "functions-consumer"]
