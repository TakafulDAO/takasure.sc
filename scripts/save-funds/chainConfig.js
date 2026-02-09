const fs = require("fs")
const path = require("path")

const CHAINS = {
    "arb-one": {
        deploymentsDir: "mainnet_arbitrum_one",
        tokens: {
            underlying: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", // USDC
            other: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", // USDT
        },
    },
    "arb-sepolia": {
        deploymentsDir: "testnet_arbitrum_sepolia",
        tokenDeployments: {
            underlying: "SFUSDC",
            other: "SFUSDT",
        },
    },
}

function getChainConfig(chainArg) {
    if (!chainArg) return null
    const cfg = CHAINS[chainArg]
    if (!cfg) {
        console.error(`Invalid --chain: ${chainArg}. Expected: arb-one | arb-sepolia`)
        process.exit(1)
    }
    return { name: chainArg, ...cfg }
}

function loadDeploymentAddress(chainCfg, contractName) {
    const filePath = path.join(
        __dirname,
        "..",
        "..",
        "deployments",
        chainCfg.deploymentsDir,
        `${contractName}.json`,
    )
    try {
        const raw = fs.readFileSync(filePath, "utf8")
        const json = JSON.parse(raw)
        if (!json.address) {
            console.error(`Missing address in ${filePath}`)
            process.exit(1)
        }
        return json.address
    } catch (err) {
        console.error(`Failed to load ${filePath}: ${err.message || err}`)
        process.exit(1)
    }
}

function getTokenAddresses(chainCfg) {
    if (chainCfg.tokens) return chainCfg.tokens
    if (chainCfg.tokenDeployments) {
        return {
            underlying: loadDeploymentAddress(chainCfg, chainCfg.tokenDeployments.underlying),
            other: loadDeploymentAddress(chainCfg, chainCfg.tokenDeployments.other),
        }
    }
    console.error("Chain config missing token definitions")
    process.exit(1)
}

function normalizeStrategyAlias(value) {
    if (!value) return ""
    const v = value.toLowerCase()
    if (v === "univ3" || v === "uni-v3" || v === "uni_v3" || v === "sfuniswapv3strategy") {
        return "uniV3"
    }
    return ""
}

function resolveStrategy(value, chainCfg) {
    const alias = normalizeStrategyAlias(value)
    if (!alias) return value
    if (!chainCfg) {
        console.error("Strategy alias requires --chain. Provide an address or use --chain.")
        process.exit(1)
    }
    if (alias === "uniV3") {
        return loadDeploymentAddress(chainCfg, "SFUniswapV3Strategy")
    }
    return value
}

function resolveStrategies(list, chainCfg) {
    return list.map((value) => resolveStrategy(value, chainCfg))
}

module.exports = {
    getChainConfig,
    getTokenAddresses,
    loadDeploymentAddress,
    resolveStrategy,
    resolveStrategies,
}
