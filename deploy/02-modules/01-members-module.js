const { network } = require("hardhat")
const { developmentChains } = require("../../utils/_networks")
const { verify } = require("../../scripts/verify")
const { deployUpgradeProxy } = require("../../utils/deployHelpers")

module.exports = async ({ deployments }) => {
    const { log } = deployments

    log("02.01. Deploying MembersModule Contract...")

    const contractName = "MembersModule"
    const initArgs = []
    const proxyPattern = "UUPS"
    const deterministicDeployment = false
    const contract = "MembersModule"

    const membersModule = await deployUpgradeProxy(
        contractName,
        initArgs,
        proxyPattern,
        deterministicDeployment,
        contract,
    )

    membersModuleImplementation = await deployments.get("MembersModule_Implementation")

    log("02.01. MembersModule Contract Deployed!")
    log("=====================================================================================")

    if (!developmentChains.includes(network.name) && process.env.ARBISCAN_API_KEY) {
        log("02. Verifying MembersModule!...")
        await verify(membersModule.address, [])
        log("02. MembersModule verified!")
        log("=====================================================================================")
        log("02. Verifying MembersModule implementation!...")
        await verify(membersModuleImplementation.address, [])
        log("02. MembersModule implementation verified!")

        log("=====================================================================================")
    }
}

module.exports.tags = ["all", "members", "modules"]
