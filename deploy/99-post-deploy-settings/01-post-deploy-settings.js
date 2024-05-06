const { networkConfig } = require("../../utils/_networks")

module.exports = async ({ deployments, getNamedAccounts }) => {
    const { log } = deployments
    const chainId = network.config.chainId
    const { deployer } = await getNamedAccounts()

    log("99.01. Post deploy settings...")

    const takaToken = await ethers.getContract("TakaToken")
    const takasurePool = await ethers.getContract("TakasurePool")

    log("99.01. Setting TakasurePool Contract as minter for TakaToken...")

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))
    await takaToken.grantRole(MINTER_ROLE, takasurePool.target)

    const isMinter = await takaToken.hasRole(MINTER_ROLE, takasurePool.target)

    isMinter
        ? log("99.01. TakasurePool is now a TakaToken minter!")
        : log("99.01. Something went wrong while setting TakasurePool as TakaToken minter!")

    log("99.01. Setting TakasurePool Contract as burner for TakaToken!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    await takaToken.grantRole(BURNER_ROLE, takasurePool.target)

    const isBurner = await takaToken.hasRole(BURNER_ROLE, takasurePool.target)

    isBurner
        ? log("99.01. TakasurePool is now a TakaToken burner!")
        : log("99.01. Something went wrong while setting TakasurePool as TakaToken burner!")

    log("99.01. Setting DAO operator as TakaToken admin...")

    const DEFAULT_ADMIN_ROLE = await takaToken.DEFAULT_ADMIN_ROLE()
    const daoOperator = networkConfig[chainId]["daoOperator"]
    await takaToken.grantRole(DEFAULT_ADMIN_ROLE, daoOperator)

    let isAdmin = await takaToken.hasRole(DEFAULT_ADMIN_ROLE, daoOperator)

    isAdmin
        ? log("99.01. DAO operator is now TakaToken admin!")
        : log("99.01. DSomething went wrong while setting DAO operator as TakaToken admin!")

    log("99.01. Previous Admin revoking...")

    isAdmin = await takaToken.hasRole(DEFAULT_ADMIN_ROLE, deployer)

    while (isAdmin) {
        await takaToken.revokeRole(DEFAULT_ADMIN_ROLE, deployer)
        isAdmin = await takaToken.hasRole(DEFAULT_ADMIN_ROLE, deployer)
    }

    log("99.01. Deployer is no longer TakaToken admin!")

    log("99.01. Post deploy settings completed!")

    log("=======================================================")
    log("=======================================================")
}

module.exports.tags = ["all", "post-deploys"]
