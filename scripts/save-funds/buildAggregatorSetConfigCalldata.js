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
const { getChainConfig, loadDeploymentAddress, resolveStrategies } = require("./chainConfig")

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

async function main() {
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
                "  --sendToSafe         Propose tx to the Arbitrum One Safe (requires --chain arb-one).",
                "  --sendTx             Send tx onchain for Arbitrum Sepolia (requires --chain arb-sepolia).",
                "  --simulateTenderly   Simulate on Tenderly before sending (arb-one only).",
                "  --tenderlyGas <uint> Gas limit override for Tenderly simulation.",
                "  --tenderlyBlock <uint|latest> Block number for Tenderly simulation.",
                "  --tenderlySimulationType <str> Optional Tenderly simulation type.",
                "  --strategies <a,b>   Strategy addresses (or uniV3 when --chain is set).",
                "  --weights <w1,w2>    Target weights in BPS (0..10000).",
            ].join("\n"),
        )
        process.exit(0)
    }

    const wantsSendToSafe = process.argv.includes("--sendToSafe")
    const wantsSendTx = process.argv.includes("--sendTx")
    const wantsSimTenderly = process.argv.includes("--simulateTenderly")
    if (wantsSendToSafe && wantsSendTx) {
        console.error("Use only one of --sendToSafe or --sendTx")
        process.exit(1)
    }
    const chainArg = getArg(
        "chain",
        wantsSendToSafe ? "arb-one" : wantsSendTx ? "arb-sepolia" : undefined,
    )
    const chainCfg = getChainConfig(chainArg)
    if (wantsSendToSafe && (!chainCfg || chainCfg.name !== "arb-one")) {
        console.error("--sendToSafe is only supported for --chain arb-one")
        process.exit(1)
    }
    if (wantsSendTx && (!chainCfg || chainCfg.name !== "arb-sepolia")) {
        console.error("--sendTx is only supported for --chain arb-sepolia")
        process.exit(1)
    }
    if (wantsSimTenderly && (!chainCfg || chainCfg.name !== "arb-one")) {
        console.error("--simulateTenderly is only supported for --chain arb-one")
        process.exit(1)
    }

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

    if (wantsSimTenderly) {
        const { SAFE_ADDRESS } = require("./safeSubmit")
        const { simulateTenderly } = require("./tenderlySimulate")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const sim = await simulateTenderly({
            chainCfg,
            from: SAFE_ADDRESS,
            to: target,
            data: setConfigCalldata,
            value: "0",
            gas: getArg("tenderlyGas"),
            blockNumber: getArg("tenderlyBlock"),
            simulationType: getArg("tenderlySimulationType"),
        })
        if (sim.simulationId) console.log("tenderlySimulationId:", sim.simulationId)
        if (sim.publicUrl) console.log("tenderlyPublicUrl:", sim.publicUrl)
        if (sim.dashboardUrl) {
            console.log("tenderlyDashboardUrl:")
            console.log(sim.dashboardUrl)
        }
        if (sim.status !== true) {
            console.error("Tenderly simulation did not return success status")
            process.exit(1)
        }
        console.log("tenderlyStatus: ok")
    }

    if (wantsSendToSafe) {
        const { SAFE_ADDRESS, sendToSafe } = require("./safeSubmit")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const result = await sendToSafe({ to: target, data: setConfigCalldata, value: "0" })
        console.log("safeAddress:", SAFE_ADDRESS)
        console.log("safeTxHash:", result.safeTxHash)
        console.log("txServiceUrl:", result.txServiceUrl)
    }

    if (wantsSendTx) {
        const { sendOnchain } = require("./sendOnchain")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const result = await sendOnchain({
            to: target,
            data: setConfigCalldata,
            value: "0",
            chainCfg,
        })
        console.log("txHash:", result.hash)
        console.log("blockNumber:", result.blockNumber)
        console.log("gasUsed:", result.gasUsed)
    }
}

main().catch((err) => {
    console.error(err)
    process.exit(1)
})
