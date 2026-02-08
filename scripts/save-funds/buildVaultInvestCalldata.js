/*
Builds calldata for SFVault.investIntoStrategy(assets, strategies, payloads).

Example:
  node scripts/save-funds/buildVaultInvestCalldata.js \
    --assets 1000000 \
    --strategies 0xStrat1,0xStrat2 \
    --payloads 0xdeadbeef,0x

Example (human-readable UniV3 action data, same payload for all strategies):
  node scripts/save-funds/buildVaultInvestCalldata.js \
    --assets 1000000 \
    --strategies 0xStrat1 \
    --otherRatioBps 5000 \
    --swapToOtherTokenIn 0xUSDC --swapToOtherTokenOut 0xUSDT --swapToOtherFee 500 --swapToOtherBps 5000 \
    --swapToUnderlyingTokenIn 0xUSDT --swapToUnderlyingTokenOut 0xUSDC --swapToUnderlyingFee 500 --swapToUnderlyingBps 5000 \
    --pmDeadline 0

Output:
  investCalldata: 0x...
*/
const { BigNumber, utils } = require("ethers")

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
                "  node scripts/save-funds/buildVaultInvestCalldata.js --assets <uint> --strategies <addr1,addr2> [--payloads <0x...,0x...>]",
                "  node scripts/save-funds/buildVaultInvestCalldata.js --assets <uint> --strategies <addr> --otherRatioBps <bps> \\",
                "    --swapToOtherTokenIn <addr> --swapToOtherTokenOut <addr> --swapToOtherFee <fee> --swapToOtherBps <bps> \\",
                "    --swapToUnderlyingTokenIn <addr> --swapToUnderlyingTokenOut <addr> --swapToUnderlyingFee <fee> --swapToUnderlyingBps <bps> \\",
                "    [--pmDeadline <uint>] [--minUnderlying <uint>] [--minOther <uint>]",
                "",
                "Examples:",
                "  node scripts/save-funds/buildVaultInvestCalldata.js \\",
                "    --assets 1000000 \\",
                "    --strategies 0xStrat1,0xStrat2 \\",
                "    --payloads 0xdeadbeef,0x",
                "  node scripts/save-funds/buildVaultInvestCalldata.js \\",
                "    --assets 1000000 \\",
                "    --strategies 0xStrat1 \\",
                "    --otherRatioBps 5000 \\",
                "    --swapToOtherTokenIn 0xUSDC --swapToOtherTokenOut 0xUSDT --swapToOtherFee 500 --swapToOtherBps 5000 \\",
                "    --swapToUnderlyingTokenIn 0xUSDT --swapToUnderlyingTokenOut 0xUSDC --swapToUnderlyingFee 500 --swapToUnderlyingBps 5000 \\",
                "    --pmDeadline 0",
                "",
                "Flags",
                "  --assets <uint>                  Amount of underlying to invest.",
                "  --minOther <uint>                Min other token out for PM actions.",
                "  --minUnderlying <uint>           Min underlying out for PM actions.",
                "  --otherRatioBps <bps>            Target otherToken ratio (0..10000).",
                "  --payloads <p1,p2>               Per-strategy payloads (hex). Length must match strategies.",
                "  --pmDeadline <uint>              PM deadline (0 = sentinel).",
                "  --strategies <a,b>               Strategy addresses for the bundle.",
                "  --swapToOtherAmountIn <uint>     Swap input amount for otherToken path (absolute).",
                "  --swapToOtherAmountOutMin <uint> Swap min out for otherToken path.",
                "  --swapToOtherBps <bps>           Swap input amount as BPS sentinel (0..10000).",
                "  --swapToOtherData <0x>           Raw swapToOtherData bytes (overrides builder).",
                "  --swapToOtherDeadline <uint>     Swap deadline for otherToken path.",
                "  --swapToOtherFee <fee>           Uniswap V3 pool fee for otherToken path.",
                "  --swapToOtherRecipient <addr>    Swap recipient (should be strategy address).",
                "  --swapToOtherTokenIn <addr>      Swap tokenIn for otherToken path.",
                "  --swapToOtherTokenOut <addr>     Swap tokenOut for otherToken path.",
                "  --swapToUnderlyingAmountIn <uint>   Swap input amount for underlying path (absolute).",
                "  --swapToUnderlyingAmountOutMin <uint> Swap min out for underlying path.",
                "  --swapToUnderlyingBps <bps>      Swap input amount as BPS sentinel (0..10000).",
                "  --swapToUnderlyingData <0x>      Raw swapToUnderlyingData bytes (overrides builder).",
                "  --swapToUnderlyingDeadline <uint>   Swap deadline for underlying path.",
                "  --swapToUnderlyingFee <fee>      Uniswap V3 pool fee for underlying path.",
                "  --swapToUnderlyingRecipient <addr>  Swap recipient (should be strategy address).",
                "  --swapToUnderlyingTokenIn <addr>    Swap tokenIn for underlying path.",
                "  --swapToUnderlyingTokenOut <addr>   Swap tokenOut for underlying path.",
            ].join("\n"),
        )
        process.exit(0)
    }

    const assets = parseUint(requireArg("assets"), "assets")
    const strategies = parseList(requireArg("strategies"), "strategies")
    const payloads = parseList(getArg("payloads"), "payloads")
    const wantsSwapBuild =
        hasSwapBuilderArgs("swapToOther") || hasSwapBuilderArgs("swapToUnderlying")
    const wantsActionData = Boolean(
        getArg("otherRatioBps") ||
            getArg("swapToOtherData") ||
            getArg("swapToUnderlyingData") ||
            getArg("pmDeadline") ||
            getArg("minUnderlying") ||
            getArg("minOther") ||
            wantsSwapBuild,
    )

    let finalPayloads = payloads

    if (!finalPayloads) {
        if (!wantsActionData) {
            finalPayloads = strategies.map(() => "0x")
        } else {
            if (wantsSwapBuild && strategies.length > 1) {
                console.error(
                    "swap data builder supports a single strategy (recipient must be that strategy)",
                )
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
                [
                    otherRatioBps,
                    swapToOtherData,
                    swapToUnderlyingData,
                    pmDeadline,
                    minUnderlying,
                    minOther,
                ],
            )
            finalPayloads = strategies.map(() => payload)
        }
    }

    if (strategies.length !== finalPayloads.length) {
        console.error("strategies and payloads length mismatch")
        process.exit(1)
    }

    const vaultIface = new utils.Interface([
        "function investIntoStrategy(uint256 assets, address[] strategies, bytes[] payloads)",
    ])
    const calldata = vaultIface.encodeFunctionData("investIntoStrategy", [
        assets,
        strategies,
        finalPayloads,
    ])

    console.log("investCalldata:", calldata)
}

main()
