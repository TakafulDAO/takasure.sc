/*
Builds calldata for SFStrategyAggregator.rebalance(bytes data).
You can provide human-readable strategies + payloads (bundle), or pass raw --data.

Example (bundle):
  node scripts/save-funds/buildAggregatorRebalanceCalldata.js \
    --strategies 0xStrat1 \
    --payloads 0xdeadbeef

Example (raw data):
  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --data 0x

Output:
  data: 0x...
  rebalanceCalldata: 0x...
*/
const { utils } = require("ethers")

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

function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --strategies <a,b> --payloads <p1,p2>",
                "  node scripts/save-funds/buildAggregatorRebalanceCalldata.js --data <0x...>",
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
        if (strategies && payloads) {
            if (strategies.length !== payloads.length) {
                console.error("strategies and payloads length mismatch")
                process.exit(1)
            }
            data = utils.defaultAbiCoder.encode(["address[]", "bytes[]"], [strategies, payloads])
        }
    }

    const iface = new utils.Interface(["function rebalance(bytes data)"])
    const rebalanceCalldata = iface.encodeFunctionData("rebalance", [data])

    console.log("data:", data)
    console.log("rebalanceCalldata:", rebalanceCalldata)
}

main()
