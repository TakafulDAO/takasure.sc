const { network, ethers, upgrades } = require("hardhat")
const { isDevnet, networkConfig } = require("../../utils/_networks")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let daoToken, daoTokenAddress, wakalaClaimAddress

    log("02.01. Deploying TakasurePool Contract...")

    if (isDevnet) {
        usdc = await deployments.get("USDC")
        usdcAddress = usdc.address
    } else {
        usdcAddress = networkConfig[chainId]["usdc"]
    }

    daoToken = await deployments.get("TSToken")
    daoTokenAddress = daoToken.address
    wakalaClaimAddress = networkConfig[chainId]["wakalaClaimAddress"]
    daoOperator = networkConfig[chainId]["daoOperator"]

    const initArgs = [usdcAddress, daoTokenAddress, wakalaClaimAddress, daoOperator]

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
}

module.exports.tags = ["all", "pool", "takasure"]
