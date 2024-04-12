const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deploySimpleContract } = require("../../utils/deployHelpers")
const { keccak256 } = require("ethers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("01.03. Post deploy settings...")

    const takaToken = await ethers.getContract("TakaToken")
    const takasurePool = await ethers.getContract("TakasurePool")

    log("01.03. Setting TakaSurePool Contract as minter for TakaToken...")

    const MINTER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MINTER_ROLE"))
    log("MINTER_ROLE", MINTER_ROLE)

    await takaToken.grantRole(MINTER_ROLE, takasurePool.target)

    log("01.03. TakaSurePool is now a TakaToken minter!")

    log("01.03. TakaSurePool Contract set as burner for TakaToken!")

    const BURNER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BURNER_ROLE"))
    log("BURNER_ROLE", BURNER_ROLE)
    await takaToken.grantRole(BURNER_ROLE, takasurePool.target)

    log("01.03. TakaSurePool is now a TakaToken burner!")

    log("=======================================================")
    log("=======================================================")
}

module.exports.tags = ["all", "takaSurePool", "token"]
