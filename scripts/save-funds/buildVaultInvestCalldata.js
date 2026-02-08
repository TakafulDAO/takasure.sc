/*
Builds calldata for SFVault.investIntoStrategy(assets, strategies, payloads).

Example:
  node scripts/save-funds/buildVaultInvestCalldata.js \
    --assets 1000000 \
    --strategies 0xStrat1,0xStrat2 \
    --payloads 0xdeadbeef,0x

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

function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/buildVaultInvestCalldata.js --assets <uint> --strategies <addr1,addr2> --payloads <0x...,0x...>",
                "",
                "Notes:",
                "  - `payloads` are per-strategy bytes (hex).",
                "  - Length of strategies and payloads must match.",
            ].join("\n"),
        )
        process.exit(0)
    }

    const assets = parseUint(requireArg("assets"), "assets")
    const strategies = parseList(requireArg("strategies"), "strategies")
    const payloads = parseList(requireArg("payloads"), "payloads")

    if (strategies.length !== payloads.length) {
        console.error("strategies and payloads length mismatch")
        process.exit(1)
    }

    const vaultIface = new utils.Interface([
        "function investIntoStrategy(uint256 assets, address[] strategies, bytes[] payloads)",
    ])
    const calldata = vaultIface.encodeFunctionData("investIntoStrategy", [
        assets,
        strategies,
        payloads,
    ])

    console.log("investCalldata:", calldata)
}

main()
