module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("99.01. Post deploy settings...")

    const takaToken = await ethers.getContract("TakaToken")
    const takasurePool = await ethers.getContract("TakasurePool")

    log("99.01. Setting TakasurePool Contract as minter for TakaToken...")

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))

    await takaToken.grantRole(MINTER_ROLE, takasurePool.target)

    log("99.01. TakasurePool is now a TakaToken minter!")

    log("99.01. TakasurePool Contract set as burner for TakaToken!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    await takaToken.grantRole(BURNER_ROLE, takasurePool.target)

    log("99.01. TakasurePool is now a TakaToken burner!")

    log("=======================================================")
    log("=======================================================")
}

module.exports.tags = ["all", "post-deploys"]
