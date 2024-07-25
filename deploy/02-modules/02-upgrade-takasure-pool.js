const { network, ethers, upgrades } = require("hardhat")
const { isDevnet, networkConfig } = require("../../utils/_networks")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let daoToken, daoTokenAddress, feeClaimAddress
    let takasureProxy, takasureProxyAddress

    log("02.02. Deploying TakasurePool Contract...")

    if (isDevnet) {
        usdc = await deployments.get("USDC")
        usdcAddress = usdc.address
    } else {
        usdcAddress = networkConfig[chainId]["usdc"]
    }

    daoToken = await deployments.get("TSToken")
    daoTokenAddress = daoToken.address
    feeClaimAddress = networkConfig[chainId]["feeClaimAddress"]
    daoOperator = networkConfig[chainId]["daoOperator"]
    takasureProxy = await deployments.get("TakasurePool")
    takasureProxyAddress = takasureProxy.address

    const initArgs = [usdcAddress, daoTokenAddress, feeClaimAddress, daoOperator]

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

module.exports.tags = ["upgrade"]
