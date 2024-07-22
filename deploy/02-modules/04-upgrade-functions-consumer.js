const { ethers, upgrades } = require("hardhat")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    let functionsConsumerProxy, functionsConsumerProxyAddress

    log("02.04. Deploying FunctionsConsumer Contract...")

    functionsConsumerProxy = await deployments.get("FunctionsConsumer")
    functionsConsumerProxyAddress = functionsConsumerProxy.address

    const FunctionsConsumerUpgrade = await ethers.getContractFactory("FunctionsConsumer")
    const functionsConsumerUpgrade = await upgrades.upgradeProxy(
        functionsConsumerProxyAddress,
        FunctionsConsumerUpgrade,
    )

    const artifact = await deployments.getArtifact("FunctionsConsumer")

    deployments.save("FunctionsConsumer", {
        abi: artifact.abi,
        address: functionsConsumerProxyAddress,
        bytecode: artifact.bytecode,
        deployedBytecode: artifact.deployedBytecode,
    })

    log("02.04. FunctionsConsumer Contract Upgraded!")
    log("=====================================================================================")
}

module.exports.tags = ["upgrade-functions-consumer"]
