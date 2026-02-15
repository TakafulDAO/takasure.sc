/*
Builds calldata for:
  SFStrategyAggregator.setDefaultWithdrawPayload(strategy, payload)

Example:
  node scripts/save-funds/buildDefaultWithdrawPayload.js \
    --recipient 0xStrategy \
    --tokenIn 0xUSDT --tokenOut 0xUSDC --fee 500 \
    --bps 10000

Example (raw payload):
  node scripts/save-funds/buildDefaultWithdrawPayload.js \
    --strategy 0xStrategy \
    --payload 0xdeadbeef

Output:
  swapToUnderlyingData: 0x... (if building UniV3 payload)
  defaultWithdrawPayload: 0x... (if building UniV3 payload)
  setDefaultWithdrawPayloadCalldata: 0x...
*/
const { BigNumber, utils } = require("ethers")
const {
    getChainConfig,
    getTokenAddresses,
    loadDeploymentAddress,
    resolveStrategy,
} = require("./chainConfig")

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

function parseBps(value, label) {
    const v = BigNumber.from(value)
    if (v.lt(0) || v.gt(10000)) {
        console.error(`${label} must be between 0 and 10000`)
        process.exit(1)
    }
    return v
}

function parseUint(value, label) {
    try {
        return BigNumber.from(value)
    } catch (e) {
        console.error(`Invalid ${label}: ${value}`)
        process.exit(1)
    }
}

function encodePath(tokenIn, fee, tokenOut) {
    return utils.solidityPack(["address", "uint24", "address"], [tokenIn, fee, tokenOut])
}

async function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js --recipient <strategy> --tokenIn <USDT> --tokenOut <USDC> --fee <poolFee> --bps <0..10000> [--chain <arb-one|arb-sepolia>]",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js --strategy <strategy|uniV3> --payload <0x...> [--chain <arb-one|arb-sepolia>]",
                "",
                "",
                "Examples:",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js \\",
                "    --recipient <STRATEGY_ADDRESS> \\",
                "    --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> \\",
                "    --bps 10000",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js \\",
                "    --recipient <STRATEGY_ADDRESS> \\",
                "    --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> \\",
                "    --bps 5000",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js \\",
                "    --recipient <STRATEGY_ADDRESS> \\",
                "    --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> \\",
                "    --bps 10000 --deadline 1700000000 --pmDeadline 1700000000 \\",
                "    --minUnderlying 1000 --minOther 0",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js \\",
                "    --recipient <STRATEGY_ADDRESS_USED_IN_SWAP_INPUT> \\",
                "    --strategy <AGGREGATOR_STRATEGY_ARG> \\",
                "    --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> \\",
                "    --bps 10000",
                "",
                "Flags",
                "  --amountOutMin <uint>    Swap min out (default 0).",
                "  --bps <0..10000>         Swap amount as BPS sentinel.",
                "  --chain <arb-one|arb-sepolia> Optional chain shortcut for token/strategy defaults.",
                "  --deadline <uint>        Swap deadline (0 = sentinel).",
                "  --fee <uint>             Uniswap V3 pool fee.",
                "  --minOther <uint>        Min other token out for PM actions.",
                "  --minUnderlying <uint>   Min underlying out for PM actions.",
                "  --otherRatioBps <bps>    Target otherToken ratio (0..10000).",
                "  --payload <0x>           Raw payload override (skips UniV3 build).",
                "  --pmDeadline <uint>      PM deadline (0 = sentinel).",
                "  --sendToSafe             Propose tx to the Arbitrum One Safe (requires --chain arb-one).",
                "  --sendTx                 Send tx onchain for Arbitrum Sepolia (requires --chain arb-sepolia).",
                "  --simulateTenderly       Simulate on Tenderly before sending (arb-one only).",
                "  --tenderlyGas <uint>     Gas limit override for Tenderly simulation.",
                "  --tenderlyBlock <uint|latest> Block number for Tenderly simulation.",
                "  --tenderlySimulationType <str> Optional Tenderly simulation type.",
                "  --recipient <addr>       Swap recipient (strategy address).",
                "  --strategy <addr>        Strategy used for calldata (default: recipient). Use uniV3 when --chain is set.",
                "  --tokenIn <addr>         Swap tokenIn.",
                "  --tokenOut <addr>        Swap tokenOut.",
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

    const rawPayload = getArg("payload")
    const recipientArg = getArg("recipient")
    const strategyArg = getArg("strategy")
    let strategy = strategyArg || recipientArg || ""
    if (chainCfg) {
        if (!strategyArg) {
            console.error("Missing --strategy (required when --chain is set)")
            process.exit(1)
        }
        strategy = resolveStrategy(strategyArg, chainCfg)
    } else if (strategy) {
        strategy = resolveStrategy(strategy, chainCfg)
    }

    const recipient = recipientArg || (chainCfg ? strategy : "")

    let defaultWithdrawPayload = rawPayload || ""
    let swapToUnderlyingData = ""
    let amountIn = BigNumber.from(0)

    if (!rawPayload) {
        const recipientReq = recipient || ""
        if (!recipientReq) {
            console.error("Missing --recipient (or provide --strategy with --chain)")
            process.exit(1)
        }

        const tokens = chainCfg ? getTokenAddresses(chainCfg) : null
        const tokenIn = getArg("tokenIn", tokens ? tokens.other : "")
        const tokenOut = getArg("tokenOut", tokens ? tokens.underlying : "")
        const feeRaw = getArg("fee")
        if (!tokenIn || !tokenOut || !feeRaw) {
            console.error("tokenIn, tokenOut and fee are required to build swap data")
            process.exit(1)
        }
        const fee = parseUint(feeRaw, "fee")
        const bps = parseBps(requireArg("bps"), "bps")

        const amountOutMin = parseUint(getArg("amountOutMin", "0"), "amountOutMin")
        const deadline = parseUint(getArg("deadline", "0"), "deadline")
        const otherRatioBps = parseBps(getArg("otherRatioBps", "0"), "otherRatioBps")
        const pmDeadline = parseUint(getArg("pmDeadline", "0"), "pmDeadline")
        const minUnderlying = parseUint(getArg("minUnderlying", "0"), "minUnderlying")
        const minOther = parseUint(getArg("minOther", "0"), "minOther")

        const AMOUNT_IN_BPS_FLAG = BigNumber.from(1).shl(255)
        amountIn = AMOUNT_IN_BPS_FLAG.or(bps)

        const path = encodePath(tokenIn, fee, tokenOut)

        const input = utils.defaultAbiCoder.encode(
            ["address", "uint256", "uint256", "bytes", "bool"],
            [recipientReq, amountIn, amountOutMin, path, true],
        )

        swapToUnderlyingData = utils.defaultAbiCoder.encode(
            ["bytes[]", "uint256"],
            [[input], deadline],
        )

        defaultWithdrawPayload = utils.defaultAbiCoder.encode(
            ["uint16", "bytes", "bytes", "uint256", "uint256", "uint256"],
            [otherRatioBps, "0x", swapToUnderlyingData, pmDeadline, minUnderlying, minOther],
        )
    }

    if (!strategy) {
        console.error("Missing --strategy (or --recipient)")
        process.exit(1)
    }

    const aggregatorIface = new utils.Interface([
        "function setDefaultWithdrawPayload(address strategy, bytes payload)",
    ])
    const setDefaultWithdrawPayloadCalldata = aggregatorIface.encodeFunctionData(
        "setDefaultWithdrawPayload",
        [strategy, defaultWithdrawPayload],
    )

    if (swapToUnderlyingData) {
        console.log("swapToUnderlyingData:", swapToUnderlyingData)
    }
    console.log("defaultWithdrawPayload:", defaultWithdrawPayload)
    console.log("setDefaultWithdrawPayloadCalldata:", setDefaultWithdrawPayloadCalldata)
    if (!amountIn.isZero()) {
        console.log("amountInSentinel:", amountIn.toString())
    }

    if (wantsSimTenderly) {
        const { SAFE_ADDRESS } = require("./safeSubmit")
        const { simulateTenderly } = require("./tenderlySimulate")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const sim = await simulateTenderly({
            chainCfg,
            from: SAFE_ADDRESS,
            to: target,
            data: setDefaultWithdrawPayloadCalldata,
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
        const result = await sendToSafe({ to: target, data: setDefaultWithdrawPayloadCalldata, value: "0" })
        console.log("safeAddress:", SAFE_ADDRESS)
        console.log("safeTxHash:", result.safeTxHash)
        console.log("txServiceUrl:", result.txServiceUrl)
    }

    if (wantsSendTx) {
        const { sendOnchain } = require("./sendOnchain")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const result = await sendOnchain({
            to: target,
            data: setDefaultWithdrawPayloadCalldata,
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

/*
Example commands:

1) Default withdraw payload (swap 100% otherToken -> underlying)
   node scripts/save-funds/buildDefaultWithdrawPayload.js ^
     --recipient <STRATEGY_ADDRESS> ^
     --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> ^
     --bps 10000

2) Swap 50% of the amount (BPS sentinel)
   node scripts/save-funds/buildDefaultWithdrawPayload.js ^
     --recipient <STRATEGY_ADDRESS> ^
     --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> ^
     --bps 5000

3) Set explicit deadlines and min-out constraints
   node scripts/save-funds/buildDefaultWithdrawPayload.js ^
     --recipient <STRATEGY_ADDRESS> ^
     --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> ^
     --bps 10000 --deadline 1700000000 --pmDeadline 1700000000 ^
     --minUnderlying 1000 --minOther 0

4) Build calldata for a different strategy address
   node scripts/save-funds/buildDefaultWithdrawPayload.js ^
     --recipient <STRATEGY_ADDRESS_USED_IN_SWAP_INPUT> ^
     --strategy <AGGREGATOR_STRATEGY_ARG> ^
     --tokenIn <USDT> --tokenOut <USDC> --fee <POOL_FEE> ^
     --bps 10000
*/
