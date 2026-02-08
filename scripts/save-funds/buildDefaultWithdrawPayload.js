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

function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js --recipient <strategy> --tokenIn <USDT> --tokenOut <USDC> --fee <poolFee> --bps <0..10000>",
                "  node scripts/save-funds/buildDefaultWithdrawPayload.js --strategy <strategy> --payload <0x...>",
                "",
                "Optional:",
                "  --strategy <address>         default: --recipient (used for calldata)",
                "  --payload <0x...>            raw payload override (skips UniV3 build)",
                "  --amountOutMin <uint>        default 0",
                "  --deadline <uint>            default 0 (sentinel => block.timestamp + 300)",
                "  --otherRatioBps <0..10000>   default 0",
                "  --pmDeadline <uint>          default 0 (sentinel => block.timestamp + 300)",
                "  --minUnderlying <uint>       default 0",
                "  --minOther <uint>            default 0",
                "",
                "Notes:",
                "  amountIn uses sentinel high-bit flag to represent BPS of swap amount.",
            ].join("\n"),
        )
        process.exit(0)
    }

    const rawPayload = getArg("payload")
    const recipient = getArg("recipient")
    const strategy = getArg("strategy", recipient || "")

    let defaultWithdrawPayload = rawPayload || ""
    let swapToUnderlyingData = ""
    let amountIn = BigNumber.from(0)

    if (!rawPayload) {
        const recipientReq = requireArg("recipient")
        const tokenIn = requireArg("tokenIn")
        const tokenOut = requireArg("tokenOut")
        const fee = parseUint(requireArg("fee"), "fee")
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
}

main()

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
