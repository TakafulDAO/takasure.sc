/*
Builds calldata for SFStrategyAggregator.harvest(bytes data).
You can provide:
  - raw --data (already ABI-encoded), or
  - --strategies with optional --payloads (defaults to empty bytes per strategy), or
  - --strategies with human-readable UniV3 action data (payload applied to all).

Example (bundle, empty payloads):
  node scripts/save-funds/buildAggregatorHarvestCalldata.js \
    --strategies 0xStrat1,0xStrat2

Example (bundle, explicit payloads):
  node scripts/save-funds/buildAggregatorHarvestCalldata.js \
    --strategies 0xStrat1,0xStrat2 \
    --payloads 0xdeadbeef,0x

Example (human-readable UniV3 action data):
  node scripts/save-funds/buildAggregatorHarvestCalldata.js \
    --strategies 0xStrat1 \
    --swapToUnderlyingTokenIn 0xUSDT --swapToUnderlyingTokenOut 0xUSDC --swapToUnderlyingFee 500 --swapToUnderlyingBps 10000 \
    --pmDeadline 0

Example (raw data / harvest all active):
  node scripts/save-funds/buildAggregatorHarvestCalldata.js --data 0x

Output:
  data: 0x...
  harvestCalldata: 0x...
*/
const { BigNumber, utils } = require("ethers")

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

function buildSwapData(prefix, defaultRecipient) {
    const dataRaw = getArg(`${prefix}Data`)
    if (dataRaw) return dataRaw

    const tokenIn = getArg(`${prefix}TokenIn`)
    const tokenOut = getArg(`${prefix}TokenOut`)
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

function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildAggregatorHarvestCalldata.js --strategies <a,b> [--payloads <p1,p2>]",
                "  node scripts/save-funds/buildAggregatorHarvestCalldata.js --strategies <addr> --otherRatioBps <bps> \\",
                "    --swapToOtherTokenIn <addr> --swapToOtherTokenOut <addr> --swapToOtherFee <fee> --swapToOtherBps <bps> \\",
                "    --swapToUnderlyingTokenIn <addr> --swapToUnderlyingTokenOut <addr> --swapToUnderlyingFee <fee> --swapToUnderlyingBps <bps> \\",
                "    [--pmDeadline <uint>] [--minUnderlying <uint>] [--minOther <uint>]",
                "  (Or provide raw: --swapToOtherData <0x> --swapToUnderlyingData <0x>)",
                "  node scripts/save-funds/buildAggregatorHarvestCalldata.js --data <0x...>",
            ].join("\n"),
        )
        process.exit(0)
    }

    const rawData = getArg("data")
    let data = "0x"

    if (rawData) {
        data = rawData
    } else {
        const strategies = parseList(getArg("strategies"), "strategies")
        const payloads = parseList(getArg("payloads"), "payloads")
        if (strategies) {
            let finalPayloads = payloads
            const wantsSwapBuild = hasSwapBuilderArgs("swapToOther") || hasSwapBuilderArgs("swapToUnderlying")
            const wantsActionData = Boolean(
                getArg("otherRatioBps") ||
                    getArg("swapToOtherData") ||
                    getArg("swapToUnderlyingData") ||
                    getArg("pmDeadline") ||
                    getArg("minUnderlying") ||
                    getArg("minOther") ||
                    wantsSwapBuild,
            )

            if (!finalPayloads) {
                if (!wantsActionData) {
                    finalPayloads = strategies.map(() => "0x")
                } else {
                    if (wantsSwapBuild && strategies.length > 1) {
                        console.error("swap data builder supports a single strategy (recipient must be that strategy)")
                        process.exit(1)
                    }

                    const otherRatioBps = parseBps(getArg("otherRatioBps", "0"), "otherRatioBps")
                    let swapToOtherData = getArg("swapToOtherData", "0x")
                    let swapToUnderlyingData = getArg("swapToUnderlyingData", "0x")
                    const pmDeadline = parseUint(getArg("pmDeadline", "0"), "pmDeadline")
                    const minUnderlying = parseUint(getArg("minUnderlying", "0"), "minUnderlying")
                    const minOther = parseUint(getArg("minOther", "0"), "minOther")

                    const singleStrategy = strategies.length === 1 ? strategies[0] : ""
                    if (swapToOtherData === "0x") {
                        swapToOtherData = buildSwapData("swapToOther", singleStrategy)
                    }
                    if (swapToUnderlyingData === "0x") {
                        swapToUnderlyingData = buildSwapData("swapToUnderlying", singleStrategy)
                    }

                    const payload = utils.defaultAbiCoder.encode(
                        ["uint16", "bytes", "bytes", "uint256", "uint256", "uint256"],
                        [otherRatioBps, swapToOtherData, swapToUnderlyingData, pmDeadline, minUnderlying, minOther],
                    )
                    finalPayloads = strategies.map(() => payload)
                }
            }
            if (strategies.length !== finalPayloads.length) {
                console.error("strategies and payloads length mismatch")
                process.exit(1)
            }
            data = utils.defaultAbiCoder.encode(["address[]", "bytes[]"], [strategies, finalPayloads])
        }
    }

    const iface = new utils.Interface(["function harvest(bytes data)"])
    const harvestCalldata = iface.encodeFunctionData("harvest", [data])

    console.log("data:", data)
    console.log("harvestCalldata:", harvestCalldata)
}

main()
