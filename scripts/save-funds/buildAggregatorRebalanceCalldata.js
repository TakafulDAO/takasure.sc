/*
Builds calldata for SFStrategyAggregator.rebalance(bytes data).
You can provide:
  - raw --data (already ABI-encoded), or
  - --strategies with optional --payloads (defaults to empty bytes per strategy), or
  - --strategies with rebalance params (ticks + optional action data), which will be
    encoded into a payload and applied to every strategy in the list.

Example (bundle, explicit payloads):
  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
    --strategies 0xStrat1,0xStrat2 \
    --payloads 0xdeadbeef,0x

Example (human-readable UniV3 rebalance):
  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
    --strategies 0xStrat1 \
    --tickLower -400 --tickUpper 400 \
    --pmDeadline 1700000000 --minUnderlying 0 --minOther 0

Example (human-readable UniV3 rebalance, encoding with action data):
  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
    --strategies 0xStrat1 \
    --tickLower -400 --tickUpper 400 \
    --otherRatioBps 5000 \
    --swapToOtherTokenIn 0xUSDC --swapToOtherTokenOut 0xUSDT --swapToOtherFee 500 --swapToOtherBps 5000 \
    --swapToUnderlyingTokenIn 0xUSDT --swapToUnderlyingTokenOut 0xUSDC --swapToUnderlyingFee 500 --swapToUnderlyingBps 5000 \
    --pmDeadline 0

Example (raw data / rebalance all active):
  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --data 0x

Output:
  data: 0x...
  rebalanceCalldata: 0x...
*/
const { BigNumber, utils } = require("ethers")
const {
    getChainConfig,
    getTokenAddresses,
    loadDeploymentAddress,
    resolveStrategies,
} = require("./chainConfig")

function getArg(name, fallback) {
    const idx = process.argv.indexOf(`--${name}`)
    if (idx === -1) return fallback
    const next = process.argv[idx + 1]
    if (!next || next.startsWith("--")) return fallback
    return next
}

function parseList(value, label) {
    if (!value) return null
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

function parseIntArg(value, label) {
    const n = Number(value)
    if (!Number.isFinite(n)) {
        console.error(`Invalid ${label}: ${value}`)
        process.exit(1)
    }
    return n
}

function parseUint(value, label) {
    try {
        return BigNumber.from(value)
    } catch (e) {
        console.error(`Invalid ${label}: ${value}`)
        process.exit(1)
    }
}

function parseBps(value, label) {
    const v = BigNumber.from(value)
    if (v.lt(0) || v.gt(10000)) {
        console.error(`${label} must be between 0 and 10000`)
        process.exit(1)
    }
    return v
}

function hasSwapBuilderArgs(prefix) {
    return Boolean(
        getArg(`${prefix}TokenIn`) ||
            getArg(`${prefix}TokenOut`) ||
            getArg(`${prefix}Fee`) ||
            getArg(`${prefix}Bps`) ||
            getArg(`${prefix}AmountIn`) ||
            getArg(`${prefix}AmountOutMin`) ||
            getArg(`${prefix}Deadline`) ||
            getArg(`${prefix}Recipient`),
    )
}

function encodePath(tokenIn, fee, tokenOut) {
    return utils.solidityPack(["address", "uint24", "address"], [tokenIn, fee, tokenOut])
}

function getTokenDefaults(prefix, chainCfg) {
    if (!chainCfg) return {}
    const tokens = getTokenAddresses(chainCfg)
    if (prefix === "swapToOther") {
        return { tokenIn: tokens.underlying, tokenOut: tokens.other }
    }
    if (prefix === "swapToUnderlying") {
        return { tokenIn: tokens.other, tokenOut: tokens.underlying }
    }
    return {}
}

function buildSwapData(prefix, defaultRecipient, chainCfg) {
    const dataRaw = getArg(`${prefix}Data`)
    if (dataRaw) return dataRaw

    const defaults = getTokenDefaults(prefix, chainCfg)
    const tokenIn = getArg(`${prefix}TokenIn`, defaults.tokenIn)
    const tokenOut = getArg(`${prefix}TokenOut`, defaults.tokenOut)
    const fee = getArg(`${prefix}Fee`)
    const bps = getArg(`${prefix}Bps`)
    const amountInRaw = getArg(`${prefix}AmountIn`)

    // No builder inputs
    if (!tokenIn && !tokenOut && !fee && !bps && !amountInRaw) return "0x"

    if (!tokenIn || !tokenOut || !fee) {
        console.error(`${prefix}: tokenIn, tokenOut and fee are required to build swap data`)
        process.exit(1)
    }

    if (!bps && !amountInRaw) {
        console.error(`${prefix}: either bps or amountIn is required`)
        process.exit(1)
    }

    if (bps && amountInRaw) {
        console.error(`${prefix}: provide either bps or amountIn (not both)`)
        process.exit(1)
    }

    const recipient = getArg(`${prefix}Recipient`, defaultRecipient || "")
    if (!recipient) {
        console.error(`${prefix}: recipient is required (use --${prefix}Recipient)`)
        process.exit(1)
    }

    const amountOutMin = parseUint(getArg(`${prefix}AmountOutMin`, "0"), `${prefix}AmountOutMin`)
    const deadline = parseUint(getArg(`${prefix}Deadline`, "0"), `${prefix}Deadline`)

    let amountIn
    if (amountInRaw) {
        amountIn = parseUint(amountInRaw, `${prefix}AmountIn`)
    } else {
        const AMOUNT_IN_BPS_FLAG = BigNumber.from(1).shl(255)
        amountIn = AMOUNT_IN_BPS_FLAG.or(parseBps(bps, `${prefix}Bps`))
    }

    const path = encodePath(tokenIn, parseUint(fee, `${prefix}Fee`), tokenOut)
    const input = utils.defaultAbiCoder.encode(
        ["address", "uint256", "uint256", "bytes", "bool"],
        [recipient, amountIn, amountOutMin, path, true],
    )
    return utils.defaultAbiCoder.encode(["bytes[]", "uint256"], [[input], deadline])
}

async function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --strategies <a,b> [--payloads <p1,p2>] [--chain <arb-one|arb-sepolia>]",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --strategies <a,b> --tickLower <int> --tickUpper <int> [--pmDeadline <uint>] [--minUnderlying <uint>] [--minOther <uint>] [--chain <arb-one|arb-sepolia>]",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --strategies <a,b> --tickLower <int> --tickUpper <int> --otherRatioBps <bps> \\",
                "    --swapToOtherTokenIn <addr> --swapToOtherTokenOut <addr> --swapToOtherFee <fee> --swapToOtherBps <bps> \\",
                "    --swapToUnderlyingTokenIn <addr> --swapToUnderlyingTokenOut <addr> --swapToUnderlyingFee <fee> --swapToUnderlyingBps <bps> \\",
                "    [--pmDeadline <uint>] [--minUnderlying <uint>] [--minOther <uint>]",
                "  (Or provide raw: --swapToOtherData <0x> --swapToUnderlyingData <0x>)",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --data <0x...>",
                "",
                "Examples:",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \\",
                "    --strategies 0xStrat1,0xStrat2 \\",
                "    --payloads 0xdeadbeef,0x",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \\",
                "    --strategies uniV3 --chain arb-one \\",
                "    --tickLower -400 --tickUpper 400 \\",
                "    --pmDeadline 1700000000 --minUnderlying 0 --minOther 0",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \\",
                "    --strategies uniV3 --chain arb-one \\",
                "    --tickLower -400 --tickUpper 400 \\",
                "    --otherRatioBps 5000 \\",
                "    --swapToOtherTokenIn 0xUSDC --swapToOtherTokenOut 0xUSDT --swapToOtherFee 500 --swapToOtherBps 5000 \\",
                "    --swapToUnderlyingTokenIn 0xUSDT --swapToUnderlyingTokenOut 0xUSDC --swapToUnderlyingFee 500 --swapToUnderlyingBps 5000 \\",
                "    --pmDeadline 0",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --data 0x",
                "",
                "Flags",
                "  --actionData <0x>                  Raw actionData for new encoding (overrides builder fields).",
                "  --chain <arb-one|arb-sepolia>      Optional chain shortcut for token/strategy defaults.",
                "  --sendToSafe                      Propose tx to the Arbitrum One Safe (requires --chain arb-one).",
                "  --sendTx                          Send tx onchain for Arbitrum Sepolia (requires --chain arb-sepolia).",
                "  --simulateTenderly                Simulate on Tenderly before sending (arb-one only).",
                "  --tenderlyGas <uint>              Gas limit override for Tenderly simulation.",
                "  --tenderlyBlock <uint|latest>     Block number for Tenderly simulation.",
                "  --tenderlySimulationType <str>    Optional Tenderly simulation type.",
                "  --data <0x>                        Raw ABI-encoded data for rebalance(bytes).",
                "  --minOther <uint>                  Min other token out for PM actions.",
                "  --minUnderlying <uint>             Min underlying out for PM actions.",
                "  --otherRatioBps <bps>              Target otherToken ratio (0..10000) for action data.",
                "  --payloads <p1,p2>                 Per-strategy payloads (hex). Length must match strategies.",
                "  --pmDeadline <uint>                PM deadline (0 = sentinel).",
                "  --strategies <a,b>                 Strategy addresses (or uniV3 when --chain is set).",
                "  --swapToOtherAmountIn <uint>       Swap input amount for otherToken path (absolute).",
                "  --swapToOtherAmountOutMin <uint>   Swap min out for otherToken path.",
                "  --swapToOtherBps <bps>             Swap input amount as BPS sentinel (0..10000).",
                "  --swapToOtherData <0x>             Raw swapToOtherData bytes (overrides builder).",
                "  --swapToOtherDeadline <uint>       Swap deadline for otherToken path.",
                "  --swapToOtherFee <fee>             Uniswap V3 pool fee for otherToken path.",
                "  --swapToOtherRecipient <addr>      Swap recipient (should be strategy address).",
                "  --swapToOtherTokenIn <addr>        Swap tokenIn for otherToken path.",
                "  --swapToOtherTokenOut <addr>       Swap tokenOut for otherToken path.",
                "  --swapToUnderlyingAmountIn <uint>  Swap input amount for underlying path (absolute).",
                "  --swapToUnderlyingAmountOutMin <uint> Swap min out for underlying path.",
                "  --swapToUnderlyingBps <bps>        Swap input amount as BPS sentinel (0..10000).",
                "  --swapToUnderlyingData <0x>        Raw swapToUnderlyingData bytes (overrides builder).",
                "  --swapToUnderlyingDeadline <uint>  Swap deadline for underlying path.",
                "  --swapToUnderlyingFee <fee>        Uniswap V3 pool fee for underlying path.",
                "  --swapToUnderlyingRecipient <addr> Swap recipient (should be strategy address).",
                "  --swapToUnderlyingTokenIn <addr>   Swap tokenIn for underlying path.",
                "  --swapToUnderlyingTokenOut <addr>  Swap tokenOut for underlying path.",
                "  --tickLower <int>                  New lower tick (required for builder).",
                "  --tickUpper <int>                  New upper tick (required for builder).",
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

    const rawData = getArg("data")
    let data = "0x"

    if (rawData) {
        data = rawData
    } else {
        const strategiesInput = parseList(getArg("strategies"), "strategies")
        const strategies = strategiesInput ? resolveStrategies(strategiesInput, chainCfg) : null
        const payloads = parseList(getArg("payloads"), "payloads")
        const tickLowerArg = getArg("tickLower")
        const tickUpperArg = getArg("tickUpper")

        if (strategies) {
            let finalPayloads = payloads
            const singleStrategy = strategies.length === 1 ? strategies[0] : ""

            if (!finalPayloads && tickLowerArg !== undefined && tickUpperArg !== undefined) {
                const tickLower = parseIntArg(tickLowerArg, "tickLower")
                const tickUpper = parseIntArg(tickUpperArg, "tickUpper")

                const actionDataRaw = getArg("actionData")
                const otherRatioBps = getArg("otherRatioBps")
                let swapToOtherData = getArg("swapToOtherData", "0x")
                let swapToUnderlyingData = getArg("swapToUnderlyingData", "0x")
                const pmDeadline = parseUint(getArg("pmDeadline", "0"), "pmDeadline")
                const minUnderlying = parseUint(getArg("minUnderlying", "0"), "minUnderlying")
                const minOther = parseUint(getArg("minOther", "0"), "minOther")

                let payload
                const wantsSwapToOtherBuild = hasSwapBuilderArgs("swapToOther")
                const wantsSwapToUnderlyingBuild = hasSwapBuilderArgs("swapToUnderlying")

                if (actionDataRaw) {
                    payload = utils.defaultAbiCoder.encode(
                        ["int24", "int24", "bytes"],
                        [tickLower, tickUpper, actionDataRaw],
                    )
                } else if (
                    otherRatioBps !== undefined ||
                    swapToOtherData !== "0x" ||
                    swapToUnderlyingData !== "0x"
                ) {
                    if (strategies.length > 1) {
                        console.error(
                            "swap data builder supports a single strategy (recipient must be that strategy)",
                        )
                        process.exit(1)
                    }
                    if (swapToOtherData === "0x") {
                        swapToOtherData = buildSwapData("swapToOther", singleStrategy, chainCfg)
                    }
                    if (swapToUnderlyingData === "0x" && wantsSwapToUnderlyingBuild) {
                        swapToUnderlyingData = buildSwapData(
                            "swapToUnderlying",
                            singleStrategy,
                            chainCfg,
                        )
                    }

                    const ratio = Number(otherRatioBps || 0)
                    if (!Number.isFinite(ratio) || ratio < 0 || ratio > 10000) {
                        console.error(`Invalid otherRatioBps (0..10000): ${otherRatioBps}`)
                        process.exit(1)
                    }
                    if (ratio > 0 && swapToUnderlyingData === "0x" && !wantsSwapToUnderlyingBuild) {
                        console.error(
                            "warning: swapToUnderlyingData not provided; strategy may revert if it needs otherToken -> underlying swaps",
                        )
                    }
                    const actionData = utils.defaultAbiCoder.encode(
                        ["uint16", "bytes", "bytes", "uint256", "uint256", "uint256"],
                        [
                            ratio,
                            swapToOtherData,
                            swapToUnderlyingData,
                            pmDeadline,
                            minUnderlying,
                            minOther,
                        ],
                    )
                    payload = utils.defaultAbiCoder.encode(
                        ["int24", "int24", "bytes"],
                        [tickLower, tickUpper, actionData],
                    )
                } else {
                    if (pmDeadline.isZero()) {
                        console.error("pmDeadline is required for legacy rebalance encoding")
                        process.exit(1)
                    }
                    payload = utils.defaultAbiCoder.encode(
                        ["int24", "int24", "uint256", "uint256", "uint256"],
                        [tickLower, tickUpper, pmDeadline, minUnderlying, minOther],
                    )
                }

                finalPayloads = strategies.map(() => payload)
            } else if (!finalPayloads) {
                finalPayloads = strategies.map(() => "0x")
            }

            if (strategies.length !== finalPayloads.length) {
                console.error("strategies and payloads length mismatch")
                process.exit(1)
            }

            data = utils.defaultAbiCoder.encode(
                ["address[]", "bytes[]"],
                [strategies, finalPayloads],
            )
        }
    }

    const iface = new utils.Interface(["function rebalance(bytes data)"])
    const rebalanceCalldata = iface.encodeFunctionData("rebalance", [data])

    console.log("data:", data)
    console.log("rebalanceCalldata:", rebalanceCalldata)

    if (wantsSimTenderly) {
        const { SAFE_ADDRESS } = require("./safeSubmit")
        const { simulateTenderly } = require("./tenderlySimulate")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const sim = await simulateTenderly({
            chainCfg,
            from: SAFE_ADDRESS,
            to: target,
            data: rebalanceCalldata,
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
        const result = await sendToSafe({ to: target, data: rebalanceCalldata, value: "0" })
        console.log("safeAddress:", SAFE_ADDRESS)
        console.log("safeTxHash:", result.safeTxHash)
        console.log("txServiceUrl:", result.txServiceUrl)
    }

    if (wantsSendTx) {
        const { sendOnchain } = require("./sendOnchain")
        const target = loadDeploymentAddress(chainCfg, "SFStrategyAggregator")
        const result = await sendOnchain({
            to: target,
            data: rebalanceCalldata,
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
node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
  --strategies 0x2e9db0a46ab897d0e1e08cca9157d06b61f8112e \
  --tickLower -594 \
  --tickUpper 606 \
  --otherRatioBps 7000 \
  --swapToOtherTokenIn 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
  --swapToOtherTokenOut 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingTokenIn 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 \
  --swapToUnderlyingTokenOut 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline 0

===========================================================

node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --tickLower -594 \
  --tickUpper 606 \
  --otherRatioBps 7000 \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline 0

  ===========================================================

  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --tickLower -594 \
  --tickUpper 606 \
  --otherRatioBps 7000 \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline 0 \
  --sendToSafe

  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --tickLower 5 \
  --tickUpper 10 \
  --pmDeadline $(( $(date +%s) + 600 )) \
  --simulateTenderly \
  --sendToSafe
*/
