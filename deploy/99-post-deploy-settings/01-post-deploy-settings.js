module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("99.01. Post deploy settings...")

    const takasurePool = await ethers.getContract("TakasurePool")
    const membersModule = await ethers.getContract("MembersModule")

    log("99.01. Setting MembersModule Contract as minter for TakaToken...")

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))

    await takasurePool.grantRole(MINTER_ROLE, membersModule.target)

    log("99.01. MembersModule is now a TakaToken minter!")

    log("99.01. MembersModule Contract set as burner for TakaToken!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    await takasurePool.grantRole(BURNER_ROLE, membersModule.target)

    log("99.01. MembersModule is now a TakaToken burner!")

    log("=======================================================")
    log("=======================================================")
}

module.exports.tags = ["all", "takaSurePool", "token"]
