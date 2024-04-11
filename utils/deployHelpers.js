//
// Deployment utilities
//

const hre = require("hardhat")

const { isMainnet, isTestnet, isRealChain, isInternal } = require("./_networks.js")
const { deterministicDeployment } = require("../hardhat.config.js")

// Wait for 6 blocks confirmation on Mainnet/Testnets.
const NUM_CONFIRMATIONS = isMainnet || isTestnet || isInternal ? 6 : 0

const deploySimpleContract = async (contractName, args, deterministicDeployment, contract) => {
    const { deploy, log } = deployments
    const { deployer } = await getNamedAccounts()
    if (!args) args = null
    if (!contract) contract = contractName
    const result = await deploy(contractName, {
        contract: contract,
        from: deployer,
        args: args,
        log: true,
        waitConfimations: NUM_CONFIRMATIONS,
        deterministicDeployment: deterministicDeployment,
    })

    return result
}

const deployUpgradeProxy = async (contractName, initArgs, contract) => {
    const { deploy, log } = deployments
    const { deployer } = await getNamedAccounts()
    if (!initArgs) initArgs = null
    if (!contract) contract = contractName
    const result = await deploy(contractName, {
        contract: contract,
        from: deployer,
        log: true,
        proxy: {
            proxyContract: "UUPS",
            execute: {
                init: {
                    methodName: "initialize",
                    args: initArgs,
                },
            },
        },
        waitConfimations: NUM_CONFIRMATIONS,
    })

    return result
}

module.exports = {
    deploySimpleContract,
}
