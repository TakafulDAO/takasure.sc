const { networkConfig } = require("../../utils/_networks")

module.exports = async ({ deployments, getNamedAccounts }) => {
    const { log } = deployments
    const chainId = network.config.chainId
    const { deployer } = await getNamedAccounts()

    log("99.01. Post deploy settings...")

    const tldToken = await ethers.getContract("TheLifeDAOToken")
    const takasurePool = await ethers.getContract("TakasurePool")

    log("99.01. Setting TakasurePool Contract as minter for The Life DAO Token...")

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))
    await tldToken.grantRole(MINTER_ROLE, takasurePool.target)

    const isMinter = await tldToken.hasRole(MINTER_ROLE, takasurePool.target)

    isMinter
        ? log("99.01. TakasurePool is now a The Life DAO Token minter!")
        : log(
              "99.01. Something went wrong while setting TakasurePool as The Life DAO Token minter!",
          )

    log("99.01. Setting TakasurePool Contract as burner for The Life DAO Token!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    await tldToken.grantRole(BURNER_ROLE, takasurePool.target)

    const isBurner = await tldToken.hasRole(BURNER_ROLE, takasurePool.target)

    isBurner
        ? log("99.01. TakasurePool is now a The Life DAO Token burner!")
        : log(
              "99.01. Something went wrong while setting TakasurePool as The Life DAO Token burner!",
          )

    log("99.01. Setting DAO operator as The Life DAO Token admin...")

    const DEFAULT_ADMIN_ROLE = await tldToken.DEFAULT_ADMIN_ROLE()
    const daoOperator = networkConfig[chainId]["daoOperator"]
    await tldToken.grantRole(DEFAULT_ADMIN_ROLE, daoOperator)

    let isAdmin = await tldToken.hasRole(DEFAULT_ADMIN_ROLE, daoOperator)

    isAdmin
        ? log("99.01. DAO operator is now The Life DAO Token admin!")
        : log(
              "99.01. DSomething went wrong while setting DAO operator as The Life DAO Token admin!",
          )

    log("99.01. Previous Admin revoking...")

    isAdmin = await tldToken.hasRole(DEFAULT_ADMIN_ROLE, deployer)

    while (isAdmin) {
        await tldToken.revokeRole(DEFAULT_ADMIN_ROLE, deployer)
        isAdmin = await tldToken.hasRole(DEFAULT_ADMIN_ROLE, deployer)
    }

    log("99.01. Deployer is no longer The Life DAO Token admin!")

    log("99.01. Post deploy settings completed!")

    log("=======================================================")
    log("=======================================================")
}

module.exports.tags = ["all", "post-deploys"]
