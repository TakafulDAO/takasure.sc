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
require("dotenv").config()
const { BigNumber, Contract, providers, utils } = require("ethers")
const {
    getChainConfig,
    getTokenAddresses,
    loadDeploymentAddress,
    resolveStrategies,
} = require("./chainConfig")

const DEFAULT_CHAIN = "arb-one"
const DEFAULT_STRATEGIES = "uniV3"
const DEFAULT_SWAP_FEE_BY_CHAIN = {
    "arb-one": "100",
    "arb-sepolia": "100",
}

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
    let v
    try {
        v = BigNumber.from(value)
    } catch (e) {
        console.error(`Invalid ${label}: ${value}`)
        process.exit(1)
    }
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

function encodePath(tokenIn, fee, tokenOut) {
    return utils.solidityPack(["address", "uint24", "address"], [tokenIn, fee, tokenOut])
}

function getDefaultSwapFee(chainCfg) {
    if (!chainCfg) return undefined
    return DEFAULT_SWAP_FEE_BY_CHAIN[chainCfg.name]
}

function getRpcUrl(chainCfg) {
    if (!chainCfg) return ""
    if (chainCfg.name === "arb-one") {
        return process.env.SAFE_RPC_URL || process.env.ARBITRUM_MAINNET_RPC_URL || ""
    }
    if (chainCfg.name === "arb-sepolia") {
        return process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL || ""
    }
    return ""
}

async function resolveAssets(assetsArg, chainCfg) {
    const normalized = String(assetsArg || "")
        .trim()
        .toLowerCase()
    if (normalized !== "full" && normalized !== "max" && normalized !== "all") {
        return parseUint(assetsArg, "assets")
    }

    if (!chainCfg) {
        console.error("--assets full|max|all requires --chain")
        process.exit(1)
    }

    const rpcUrl = getRpcUrl(chainCfg)
    if (!rpcUrl) {
        if (chainCfg.name === "arb-one") {
            console.error(
                "Missing SAFE_RPC_URL or ARBITRUM_MAINNET_RPC_URL (required for --assets full|max|all)",
            )
            process.exit(1)
        }
        if (chainCfg.name === "arb-sepolia") {
            console.error(
                "Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL (required for --assets full|max|all)",
            )
            process.exit(1)
        }
        console.error("Missing RPC URL for selected --chain")
        process.exit(1)
    }

    const vault = loadDeploymentAddress(chainCfg, "SFVault")
    const provider = new providers.JsonRpcProvider(rpcUrl)
    const vaultContract = new Contract(
        vault,
        ["function idleAssets() view returns (uint256)"],
        provider,
    )
    let idleAssets
    try {
        idleAssets = await vaultContract.idleAssets()
    } catch (e) {
        console.error(`Failed to read SFVault.idleAssets(): ${e.message || e}`)
        process.exit(1)
    }

    if (idleAssets.lte(0)) {
        console.error("SFVault.idleAssets() is 0; nothing to invest")
        process.exit(1)
    }

    console.log("resolvedAssets:", idleAssets.toString())
    return idleAssets
}

function buildSwapData(prefix, defaultRecipient, chainCfg, defaultFee) {
    const dataRaw = getArg(`${prefix}Data`)
    if (dataRaw) return dataRaw

    const defaults = getTokenDefaults(prefix, chainCfg)
    const tokenIn = getArg(`${prefix}TokenIn`, defaults.tokenIn)
    const tokenOut = getArg(`${prefix}TokenOut`, defaults.tokenOut)
    const fee = getArg(`${prefix}Fee`, defaultFee)
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
                "  node scripts/save-funds/buildVaultInvestCalldata.js --assets <uint|full|max|all> [--strategies <addr1,addr2>] [--payloads <0x...,0x...>] [--chain <arb-one|arb-sepolia>]",
                "  node scripts/save-funds/buildVaultInvestCalldata.js --assets <uint|full|max|all> [--strategies <addr|uniV3>] --otherRatioBps <bps> \\",
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
                "    --strategies uniV3 --chain arb-one \\",
                "    --otherRatioBps 5000 \\",
                "    --swapToOtherBps 5000 \\",
                "    --swapToUnderlyingBps 5000 \\",
                "    --pmDeadline 0",
                "  node scripts/save-funds/buildVaultInvestCalldata.js \\",
                "    --assets full",
                "",
                "Flags",
                "  --assets <uint|full|max|all>     Amount of underlying to invest; full/max/all = SFVault.idleAssets().",
                "  --chain <arb-one|arb-sepolia>    Chain shortcut for defaults. Defaults to arb-one.",
                "  --defaultSwapFee <fee>           Default Uniswap V3 fee for swap builders when --swapTo*Fee is omitted.",
                "  --sendToSafe                    Propose tx to the Arbitrum One Safe (requires --chain arb-one).",
                "  --sendTx                        Send tx onchain for Arbitrum Sepolia (requires --chain arb-sepolia).",
                "  --simulateTenderly              Simulate on Tenderly before sending (arb-one only).",
                "  --tenderlyGas <uint>            Gas limit override for Tenderly simulation.",
                "  --tenderlyBlock <uint|latest>   Block number for Tenderly simulation.",
                "  --tenderlySimulationType <str>  Optional Tenderly simulation type.",
                "  --minOther <uint>                Min other token out for PM actions.",
                "  --minUnderlying <uint>           Min underlying out for PM actions.",
                "  --otherRatioBps <bps>            Target otherToken ratio (0..10000).",
                "  --payloads <p1,p2>               Per-strategy payloads (hex). Length must match strategies.",
                "  --pmDeadline <uint>              PM deadline (0 = sentinel).",
                "  --strategies <a,b>               Strategy addresses (or uniV3). Defaults to uniV3.",
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

    const wantsSendToSafe = process.argv.includes("--sendToSafe")
    const wantsSendTx = process.argv.includes("--sendTx")
    const wantsSimTenderly = process.argv.includes("--simulateTenderly")
    if (wantsSendToSafe && wantsSendTx) {
        console.error("Use only one of --sendToSafe or --sendTx")
        process.exit(1)
    }
    const chainArg = getArg(
        "chain",
        wantsSendToSafe ? "arb-one" : wantsSendTx ? "arb-sepolia" : DEFAULT_CHAIN,
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

    const assets = await resolveAssets(requireArg("assets"), chainCfg)
    const strategiesInput = parseList(getArg("strategies", DEFAULT_STRATEGIES), "strategies")
    if (!strategiesInput) {
        console.error("Missing --strategies")
        process.exit(1)
    }
    const strategies = resolveStrategies(strategiesInput, chainCfg)
    const payloads = parseList(getArg("payloads"), "payloads")
    const defaultSwapFee = getArg("defaultSwapFee", getDefaultSwapFee(chainCfg))
    const wantsSwapToOtherBuild = hasSwapBuilderArgs("swapToOther")
    const wantsSwapToUnderlyingBuild = hasSwapBuilderArgs("swapToUnderlying")
    const wantsSwapBuild = wantsSwapToOtherBuild || wantsSwapToUnderlyingBuild
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
            if (swapToOtherData === "0x" && wantsSwapToOtherBuild) {
                swapToOtherData = buildSwapData(
                    "swapToOther",
                    singleStrategy,
                    chainCfg,
                    defaultSwapFee,
                )
            }
            if (swapToUnderlyingData === "0x" && wantsSwapToUnderlyingBuild) {
                swapToUnderlyingData = buildSwapData(
                    "swapToUnderlying",
                    singleStrategy,
                    chainCfg,
                    defaultSwapFee,
                )
            }
            if (otherRatioBps.gt(0) && swapToOtherData === "0x" && !wantsSwapToOtherBuild) {
                console.error(
                    "warning: swapToOtherData not provided; strategy may revert if it needs underlying -> otherToken swaps",
                )
            }
            if (
                otherRatioBps.gt(0) &&
                swapToUnderlyingData === "0x" &&
                !wantsSwapToUnderlyingBuild
            ) {
                console.error(
                    "warning: swapToUnderlyingData not provided; strategy may revert if it needs otherToken -> underlying swaps",
                )
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

    if (wantsSimTenderly) {
        const { SAFE_ADDRESS } = require("./safeSubmit")
        const { simulateTenderly } = require("./tenderlySimulate")
        const target = loadDeploymentAddress(chainCfg, "SFVault")
        const sim = await simulateTenderly({
            chainCfg,
            from: SAFE_ADDRESS,
            to: target,
            data: calldata,
            value: "0",
            gas: getArg("tenderlyGas"),
            blockNumber: getArg("tenderlyBlock"),
            simulationType: getArg("tenderlySimulationType"),
        })
        if (sim.simulationId) console.log("tenderlySimulationId:", sim.simulationId)
        if (sim.publicUrl) console.log("tenderlyPublicUrl:", sim.publicUrl)
        if (sim.status !== true) {
            console.error("Tenderly simulation did not return success status")
            process.exit(1)
        }
        console.log("tenderlyStatus: ok")
    }

    if (wantsSendToSafe) {
        const { SAFE_ADDRESS, sendToSafe } = require("./safeSubmit")
        const target = loadDeploymentAddress(chainCfg, "SFVault")
        const result = await sendToSafe({ to: target, data: calldata, value: "0" })
        console.log("safeAddress:", SAFE_ADDRESS)
        console.log("safeTxHash:", result.safeTxHash)
        console.log("txServiceUrl:", result.txServiceUrl)
    }

    if (wantsSendTx) {
        const { sendOnchain } = require("./sendOnchain")
        const target = loadDeploymentAddress(chainCfg, "SFVault")
        const result = await sendOnchain({ to: target, data: calldata, value: "0", chainCfg })
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
node scripts/save-funds/buildVaultInvestCalldata.js \
  --chain arb-one \
  --assets 300000000 \
  --strategies uniV3 \
  --otherRatioBps 5150 \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 600 )) \
  --simulateTenderly \
  --sendToSafe
*/

/*
POOL=0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6
cast call --rpc-url $ARBITRUM_MAINNET_RPC_URL $POOL "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
*/

// todo: calculate better the other ratio to other token
