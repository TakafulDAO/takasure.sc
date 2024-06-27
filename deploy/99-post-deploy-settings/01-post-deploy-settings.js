const { networkConfig, isTestnet } = require("../../utils/_networks")

module.exports = async ({ deployments, getNamedAccounts }) => {
    const { log } = deployments
    const chainId = network.config.chainId
    const { deployer } = await getNamedAccounts()

    log("99.01. Post deploy settings...")

    const daoToken = await ethers.getContract("TSToken")
    const takasurePool = await ethers.getContract("TakasurePool")

    log("99.01. Setting TakasurePool Contract as minter for the DAO Token...")

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))
    await daoToken.grantRole(MINTER_ROLE, takasurePool.target)

    const isMinter = await daoToken.hasRole(MINTER_ROLE, takasurePool.target)

    isMinter
        ? log("99.01. TakasurePool is now a DAO Token minter!")
        : log("99.01. Something went wrong while setting TakasurePool as a DAO Token minter!")

    log("99.01. Setting TakasurePool Contract as burner for DAO Token!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    await daoToken.grantRole(BURNER_ROLE, takasurePool.target)

    const isBurner = await daoToken.hasRole(BURNER_ROLE, takasurePool.target)

    isBurner
        ? log("99.01. TakasurePool is now a DAO Token burner!")
        : log("99.01. Something went wrong while setting TakasurePool as a DAO Token burner!")

    if(!isTestnet) {
        log("99.01. Setting DAO operator as a DAO Token admin...")

        const DEFAULT_ADMIN_ROLE = await daoToken.DEFAULT_ADMIN_ROLE()
        const daoOperator = networkConfig[chainId]["daoOperator"]
        await daoToken.grantRole(DEFAULT_ADMIN_ROLE, daoOperator)

        let isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, daoOperator)

        isAdmin
            ? log("99.01. DAO operator is now a DAO Token admin!")
            : log("99.01. Something went wrong while setting DAO operator as a DAO Token admin!")

        log("99.01. Previous Admin revoking...")

        isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, deployer)

        while (isAdmin) {
            await daoToken.revokeRole(DEFAULT_ADMIN_ROLE, deployer)
            isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, deployer)
        }

        log("99.01. Deployer is no longer a DAO Token admin!")
    }

    log("99.01. Post deploy settings completed!")

    log("=======================================================")
    log("=======================================================")
}

module.exports.tags = ["all", "post-deploy"]
