const { ethers, upgrades } = require("hardhat")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    let takasureProxy, takasureProxyAddress

    log("02.02. Deploying TakasurePool Contract...")

    takasureProxy = await deployments.get("TakasurePool")
    takasureProxyAddress = takasureProxy.address

    const TakasurePoolUpgrade = await ethers.getContractFactory("TakasurePool")
    const takasurePoolUpgrade = await upgrades.upgradeProxy(
        takasureProxyAddress,
        TakasurePoolUpgrade,
    )

    const artifact = await deployments.getArtifact("TakasurePool")

    deployments.save("TakasurePool", {
        abi: artifact.abi,
        address: takasureProxyAddress,
        bytecode: artifact.bytecode,
        deployedBytecode: artifact.deployedBytecode,
    })

    log("02.02. TakasurePool Contract Upgraded!")
    log("=====================================================================================")
}

module.exports.tags = ["upgrade-takasure-pool"]
