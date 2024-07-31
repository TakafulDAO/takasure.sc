const { network, ethers, upgrades } = require("hardhat")
const { isDevnet, isTestnet, networkConfig, developmentChains } = require("../../utils/_networks")
const { getImplementationAddress } = require("@openzeppelin/upgrades-core")
const { verify } = require("../../scripts/verify")

module.exports = async ({ deployments }) => {
    const { log } = deployments
    const chainId = network.config.chainId

    let usdc, usdcAddress
    let feeClaimAddress, daoOperator, tokenAdmin
    let tokenName, tokenSymbol

    log("01.01. Deploying TakasurePool Contract...")

    if (isDevnet) {
        usdc = await deployments.get("USDC")
        usdcAddress = usdc.address
    } else {
        usdcAddress = networkConfig[chainId]["usdc"]
    }

    feeClaimAddress = networkConfig[chainId]["feeClaimAddress"]
    daoOperator = networkConfig[chainId]["daoOperator"]
    tokenAdmin = networkConfig[chainId]["tokenAdmin"]
    tokenName = "Takasure DAO Token"
    tokenSymbol = "TST"

    const initArgs = [usdcAddress, feeClaimAddress, daoOperator, tokenAdmin, tokenName, tokenSymbol]

    const TakasurePool = await ethers.getContractFactory("TakasurePool")
    const takasurePool = await upgrades.deployProxy(TakasurePool, initArgs)

    await takasurePool.waitForDeployment()

    takasurePoolAddress = await takasurePool.getAddress()
    const takasureArtifact = await deployments.getArtifact("TakasurePool")

    log("01.01. Writing TakasurePool Contract Deployment Data...")

    deployments.save("TakasurePool", {
        abi: takasureArtifact.abi,
        address: takasurePoolAddress,
        bytecode: takasureArtifact.bytecode,
        deployedBytecode: takasureArtifact.deployedBytecode,
    })
    log("01.01. TakasurePool Contract Deployed!")

    log("01.01. TakasurePool Data stored in the deployments folder")

    log("01.01. Getting the Dao Token Address...")
    const daoTokenAddress = await takasurePool.getDaoTokenAddress()

    const daoTokenArtifact = await deployments.getArtifact("TSToken")

    log("01.01. Writing DAO token Contract Deployment Data...")

    deployments.save("TSToken", {
        abi: daoTokenArtifact.abi,
        address: daoTokenAddress,
        bytecode: daoTokenArtifact.bytecode,
        deployedBytecode: daoTokenArtifact.deployedBytecode,
    })

    log("01.01. DAO token Data stored in the deployments folder")

    log("01.01. Setting TakasurePool Contract as minter for the DAO Token...")

    const daoToken = await ethers.getContractAt("TSToken", daoTokenAddress)

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))
    await daoToken.grantRole(MINTER_ROLE, takasurePool.target)

    const isMinter = await daoToken.hasRole(MINTER_ROLE, takasurePool.target)

    isMinter
        ? log("01.01. TakasurePool is now a DAO Token minter!")
        : log("01.01. Something went wrong while setting TakasurePool as a DAO Token minter!")

    log("01.01. Setting TakasurePool Contract as burner for DAO Token!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    await daoToken.grantRole(BURNER_ROLE, takasurePool.target)

    const isBurner = await daoToken.hasRole(BURNER_ROLE, takasurePool.target)

    isBurner
        ? log("01.01. TakasurePool is now a DAO Token burner!")
        : log("01.01. Something went wrong while setting TakasurePool as a DAO Token burner!")

    if (!isTestnet) {
        log("01.01. Setting DAO operator as a DAO Token admin...")

        const DEFAULT_ADMIN_ROLE = await daoToken.DEFAULT_ADMIN_ROLE()
        const daoOperator = networkConfig[chainId]["daoOperator"]
        await daoToken.grantRole(DEFAULT_ADMIN_ROLE, daoOperator)

        let isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, daoOperator)

        isAdmin
            ? log("01.01. DAO operator is now a DAO Token admin!")
            : log("01.01. Something went wrong while setting DAO operator as a DAO Token admin!")

        log("01.01. Previous Admin revoking...")

        isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, tokenAdmin)

        while (isAdmin) {
            await daoToken.revokeRole(DEFAULT_ADMIN_ROLE, tokenAdmin)
            isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, tokenAdmin)
        }

        log("01.01. Deployer is no longer a DAO Token admin!")
    }

    log("=====================================================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        const rpcUrl = networkConfig[chainId]["rpcUrl"]
        const provider = new ethers.JsonRpcProvider(rpcUrl)

        const impleAddress = await getImplementationAddress(provider, takasurePoolAddress)
        console.log("02.01. TakasurePool Implementation Address: ", impleAddress)

        log("01.01. Verifying Implementation!... ")
        await verify(impleAddress, [])
        log("01.01. Implementation Verified! ")

        log("01.01. Verifying Dao Token Address!... ")
        await verify(daoTokenAddress, [tokenName, tokenSymbol])
        log("01.01. Dao Token Address Verified! ")
    }
    log("=======================================================")
}

module.exports.tags = ["all", "pool", "takasure"]
