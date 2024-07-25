const { network, ethers, upgrades } = require("hardhat")
const { isDevnet, networkConfig, developmentChains } = require("../../utils/_networks")
const { getImplementationAddress } = require("@openzeppelin/upgrades-core")
const { verify } = require("../../scripts/verify")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let daoToken, daoTokenAddress, feeClaimAddress

    log("02.01. Deploying TakasurePool Contract...")

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

    const initArgs = [usdcAddress, daoTokenAddress, feeClaimAddress, daoOperator]

    const TakasurePool = await ethers.getContractFactory("TakasurePool")
    const takasurePool = await upgrades.deployProxy(TakasurePool, initArgs)
    await takasurePool.waitForDeployment()

    takasurePoolAddress = await takasurePool.getAddress()
    const artifact = await deployments.getArtifact("TakasurePool")

    log("02.01. Writing TakasurePool Contract Deployment Data...")

    deployments.save("TakasurePool", {
        abi: artifact.abi,
        address: takasurePoolAddress,
        bytecode: artifact.bytecode,
        deployedBytecode: artifact.deployedBytecode,
    })

    log("02.01. TakasurePool Data stored in the deployments folder")
    log("02.01. TakasurePool Contract Deployed!")
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

module.exports.tags = ["all", "pool", "takasure"]
