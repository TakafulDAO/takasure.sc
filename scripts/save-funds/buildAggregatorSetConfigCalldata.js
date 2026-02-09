/*
Builds calldata for SFStrategyAggregator.setConfig(newConfig),
where newConfig = abi.encode(address[] strategies, uint16[] weightsBps, bool[] actives).

Example:
  node scripts/save-funds/buildAggregatorSetConfigCalldata.js \
    --strategies 0xStrat1,0xStrat2 \
    --weights 7000,3000 \
    --actives true,true

Output:
  newConfig: 0x...
  setConfigCalldata: 0x...
*/
const { utils } = require("ethers")
const { getChainConfig, resolveStrategies } = require("./chainConfig")

function getArg(name, fallback) {
    const idx = process.argv.indexOf(`--${name}`)
    if (idx === -1) return fallback
    const next = process.argv[idx + 1]
    if (!next || next.startsWith("--")) return fallback
    return next
}

function requireArg(name) {
    const v = getArg(name)
    if (!v) {
        console.error(`Missing --${name}`)
        process.exit(1)
    }
    return v
}

function parseList(value, label) {
    const items = value
        .split(",")
        .map((v) => v.trim())
        .filter((v) => v.length > 0)
    if (items.length === 0) {
        console.error(`${label} must not be empty`)
        process.exit(1)
    }
    return items
}

function parseWeights(value) {
    return parseList(value, "weights").map((v) => {
        const n = Number(v)
        if (!Number.isFinite(n) || n < 0 || n > 10000) {
            console.error(`Invalid weight (0..10000): ${v}`)
            process.exit(1)
        }
        return n
    })
}

function parseActives(value) {
    return parseList(value, "actives").map((v) => {
        const s = v.toLowerCase()
        if (s === "true" || s === "1" || s === "yes") return true
        if (s === "false" || s === "0" || s === "no") return false
        console.error(`Invalid active flag (true/false/1/0/yes/no): ${v}`)
        process.exit(1)
    })
}

function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildAggregatorSetConfigCalldata.js --strategies <a,b> --weights <w1,w2> --actives <t1,t2> [--chain <arb-one|arb-sepolia>]",
                "",
                "Examples:",
                "  node scripts/save-funds/buildAggregatorSetConfigCalldata.js \\",
                "    --strategies 0xStrat1,0xStrat2 \\",
                "    --weights 7000,3000 \\",
                "    --actives true,true",
                "",
                "Flags",
                "  --actives <t1,t2>    Strategy active flags (true/false/1/0/yes/no).",
                "  --chain <arb-one|arb-sepolia> Optional chain shortcut for strategy addresses.",
                "  --strategies <a,b>   Strategy addresses (or uniV3 when --chain is set).",
                "  --weights <w1,w2>    Target weights in BPS (0..10000).",
            ].join("\n"),
        )
        process.exit(0)
    }

    const chainCfg = getChainConfig(getArg("chain"))
    const strategiesInput = parseList(requireArg("strategies"), "strategies")
    const strategies = resolveStrategies(strategiesInput, chainCfg)
    const weights = parseWeights(requireArg("weights"))
    const actives = parseActives(requireArg("actives"))

    if (strategies.length !== weights.length || strategies.length !== actives.length) {
        console.error("strategies, weights, and actives length mismatch")
        process.exit(1)
    }

    const newConfig = utils.defaultAbiCoder.encode(
        ["address[]", "uint16[]", "bool[]"],
        [strategies, weights, actives],
    )

    const iface = new utils.Interface(["function setConfig(bytes newConfig)"])
    const setConfigCalldata = iface.encodeFunctionData("setConfig", [newConfig])

    console.log("newConfig:", newConfig)
    console.log("setConfigCalldata:", setConfigCalldata)
}

main()
