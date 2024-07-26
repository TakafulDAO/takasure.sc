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

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        const rpcUrl = networkConfig[chainId]["rpcUrl"]
        const provider = new ethers.JsonRpcProvider(rpcUrl)

        const impleAddress = await getImplementationAddress(provider, takasurePoolAddress)
        console.log("02.01. TakasurePool Implementation Address: ", impleAddress)

        log("02.01. Verifying Implementation!... ")
        await verify(impleAddress, [])
        log("02.01. Implementation Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["upgrade-takasure-pool"]
