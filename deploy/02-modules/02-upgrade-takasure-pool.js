const { network, ethers, upgrades } = require("hardhat")
const { isDevnet, networkConfig } = require("../../utils/_networks")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let daoToken, daoTokenAddress, wakalaClaimAddress
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
    wakalaClaimAddress = networkConfig[chainId]["wakalaClaimAddress"]
    daoOperator = networkConfig[chainId]["daoOperator"]
    takasureProxy = await deployments.get("TakasurePool")
    takasureProxyAddress = takasureProxy.address

    const initArgs = [usdcAddress, daoTokenAddress, wakalaClaimAddress, daoOperator]

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

module.exports.tags = ["upgrade"]
