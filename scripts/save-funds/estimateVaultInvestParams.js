/*
Estimate UniV3 invest parameters without sending a transaction.

It reads current on-chain strategy/pool state and prints:
  - suggested --otherRatioBps (LP-target ratio)
  - suggested --swapToOtherBps and --swapToUnderlyingBps
  - estimated underlying/other amounts added to LP

Notes:
  - This is an estimate. It ignores swap fees, slippage, and price movement between estimate and execution.
  - The estimate includes current strategy token balances plus incoming --assets (same flow as strategy.deposit()).

Examples:
  node scripts/save-funds/estimateVaultInvestParams.js --assets 300000000
  node scripts/save-funds/estimateVaultInvestParams.js --assets full --chain arb-one --strategies uniV3
*/
require("dotenv").config()
const { BigNumber, Contract, providers, utils } = require("ethers")
const {
    getChainConfig,
    loadDeploymentAddress,
    resolveStrategies,
} = require("./chainConfig")

const DEFAULT_CHAIN = "arb-one"
const DEFAULT_STRATEGY = "uniV3"

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
    } catch {
        console.error(`Invalid ${label}: ${value}`)
        process.exit(1)
    }
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

async function resolveAssets(assetsArg, chainCfg, provider) {
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
    const vaultAddress = loadDeploymentAddress(chainCfg, "SFVault")
    const vault = new Contract(
        vaultAddress,
        ["function idleAssets() view returns (uint256)"],
        provider,
    )
    try {
        const idle = await vault.idleAssets()
        if (idle.lte(0)) {
            console.error("SFVault.idleAssets() is 0; nothing to estimate")
            process.exit(1)
        }
        return idle
    } catch (e) {
        console.error(`Failed to read SFVault.idleAssets(): ${e.message || e}`)
        process.exit(1)
    }
}

function getSqrtRatioApproxFromTick(tick) {
    return Math.pow(1.0001, tick / 2)
}

function quoteOtherAsUnderlyingAtPrice(otherAmount, priceToken1PerToken0, otherIsToken0) {
    if (otherAmount <= 0) return 0
    if (otherIsToken0) return otherAmount * priceToken1PerToken0
    return otherAmount / priceToken1PerToken0
}

function quoteUnderlyingAsOtherAtPrice(underlyingAmount, priceToken1PerToken0, otherIsToken0) {
    if (underlyingAmount <= 0) return 0
    if (otherIsToken0) return underlyingAmount / priceToken1PerToken0
    return underlyingAmount * priceToken1PerToken0
}

function computeOtherRatioBpsFromTicks({
    currentTick,
    tickLower,
    tickUpper,
    token0,
    token1,
    underlying,
    other,
}) {
    const t0 = token0.toLowerCase()
    const t1 = token1.toLowerCase()
    const under = underlying.toLowerCase()
    const oth = other.toLowerCase()

    if ((under !== t0 && under !== t1) || (oth !== t0 && oth !== t1) || under === oth) {
        console.error("Failed to compute auto ratio: strategy/pool token mismatch")
        process.exit(1)
    }

    const otherIsToken0 = oth === t0
    const sa = getSqrtRatioApproxFromTick(tickLower)
    const sb = getSqrtRatioApproxFromTick(tickUpper)
    const s = getSqrtRatioApproxFromTick(currentTick)

    if (
        !(sa > 0) ||
        !(sb > 0) ||
        !(s > 0) ||
        !Number.isFinite(sa) ||
        !Number.isFinite(sb) ||
        !Number.isFinite(s)
    ) {
        console.error("Failed to compute auto ratio: invalid sqrt values")
        process.exit(1)
    }

    if (s <= sa) return otherIsToken0 ? 10000 : 0
    if (s >= sb) return otherIsToken0 ? 0 : 10000

    const amount0 = (sb - s) / (s * sb)
    const amount1 = s - sa
    const priceToken1PerToken0 = s * s

    let otherValueInUnderlying
    let totalValueInUnderlying

    if (otherIsToken0) {
        otherValueInUnderlying = amount0 * priceToken1PerToken0
        totalValueInUnderlying = amount1 + otherValueInUnderlying
    } else {
        otherValueInUnderlying = amount1 / priceToken1PerToken0
        totalValueInUnderlying = amount0 + otherValueInUnderlying
    }

    if (!(totalValueInUnderlying > 0) || !Number.isFinite(totalValueInUnderlying)) return 0

    const ratio = otherValueInUnderlying / totalValueInUnderlying
    const bps = Math.round(ratio * 10000)
    if (bps < 0) return 0
    if (bps > 10000) return 10000
    return bps
}

function estimateLiquidityUse({
    sqrtCurrent,
    sqrtLower,
    sqrtUpper,
    amount0Balance,
    amount1Balance,
}) {
    if (sqrtCurrent <= sqrtLower) {
        return { used0: amount0Balance, used1: 0 }
    }
    if (sqrtCurrent >= sqrtUpper) {
        return { used0: 0, used1: amount1Balance }
    }

    const coef0 = (sqrtUpper - sqrtCurrent) / (sqrtCurrent * sqrtUpper)
    const coef1 = sqrtCurrent - sqrtLower
    if (!(coef0 > 0) || !(coef1 > 0)) return { used0: 0, used1: 0 }

    const liqFrom0 = amount0Balance / coef0
    const liqFrom1 = amount1Balance / coef1
    const liq = Math.max(0, Math.min(liqFrom0, liqFrom1))

    return {
        used0: Math.max(0, liq * coef0),
        used1: Math.max(0, liq * coef1),
    }
}

function toNumberAmount(valueBn, decimals) {
    return Number(utils.formatUnits(valueBn, decimals))
}

function fmt(value, decimals = 6) {
    if (!Number.isFinite(value)) return "n/a"
    return value.toFixed(decimals)
}

function rawEstimate(value, decimals) {
    if (!Number.isFinite(value)) return "n/a"
    if (decimals > 12) return "n/a"
    const factor = 10 ** decimals
    const raw = Math.round(Math.max(0, value) * factor)
    return String(raw)
}

async function readValuationTick(pool, twapWindow) {
    const window = Number(twapWindow.toString())
    if (window > 0) {
        try {
            const [tickCumulatives] = await pool.observe([window, 0])
            const delta = Number(tickCumulatives[1].sub(tickCumulatives[0]).toString())
            let avgTick = Math.trunc(delta / window)
            if (delta < 0 && delta % window !== 0) avgTick -= 1
            return avgTick
        } catch {
            // fall through to spot
        }
    }
    const slot0 = await pool.slot0()
    return Number(slot0.tick)
}

async function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/estimateVaultInvestParams.js --assets <uint|full|max|all> [--strategies <addr|uniV3>] [--chain <arb-one|arb-sepolia>]",
                "",
                "Flags:",
                "  --assets <uint|full|max|all>   Incoming underlying amount to estimate.",
                "  --chain <arb-one|arb-sepolia>  Chain shortcut (defaults to arb-one).",
                "  --strategies <addr|uniV3>      Single strategy address or alias (defaults to uniV3).",
                "",
                "Output:",
                "  suggestedOtherRatioBps",
                "  suggestedSwapToOtherBps",
                "  suggestedSwapToUnderlyingBps",
                "  estimatedUnderlyingAdded",
                "  estimatedOtherAdded",
            ].join("\n"),
        )
        process.exit(0)
    }

    const chainArg = getArg("chain", DEFAULT_CHAIN)
    const chainCfg = getChainConfig(chainArg)
    const rpcUrl = getRpcUrl(chainCfg)
    if (!rpcUrl) {
        if (chainCfg.name === "arb-one") {
            console.error("Missing SAFE_RPC_URL or ARBITRUM_MAINNET_RPC_URL")
            process.exit(1)
        }
        if (chainCfg.name === "arb-sepolia") {
            console.error("Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL")
            process.exit(1)
        }
        console.error("Missing RPC URL")
        process.exit(1)
    }

    const provider = new providers.JsonRpcProvider(rpcUrl)
    const assets = await resolveAssets(requireArg("assets"), chainCfg, provider)
    const strategiesInput = parseList(getArg("strategies", DEFAULT_STRATEGY), "strategies")
    if (!strategiesInput || strategiesInput.length !== 1) {
        console.error("Provide exactly one strategy via --strategies (or omit to use default uniV3)")
        process.exit(1)
    }
    const strategyAddress = resolveStrategies(strategiesInput, chainCfg)[0]

    const strategy = new Contract(
        strategyAddress,
        [
            "function pool() view returns (address)",
            "function tickLower() view returns (int24)",
            "function tickUpper() view returns (int24)",
            "function asset() view returns (address)",
            "function otherToken() view returns (address)",
            "function twapWindow() view returns (uint32)",
        ],
        provider,
    )

    let poolAddress
    let tickLower
    let tickUpper
    let underlyingAddress
    let otherAddress
    let twapWindow
    try {
        ;[poolAddress, tickLower, tickUpper, underlyingAddress, otherAddress, twapWindow] =
            await Promise.all([
                strategy.pool(),
                strategy.tickLower(),
                strategy.tickUpper(),
                strategy.asset(),
                strategy.otherToken(),
                strategy.twapWindow(),
            ])
    } catch (e) {
        console.error(`Failed reading strategy config: ${e.message || e}`)
        process.exit(1)
    }

    const pool = new Contract(
        poolAddress,
        [
            "function token0() view returns (address)",
            "function token1() view returns (address)",
            "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool)",
            "function observe(uint32[] secondsAgos) view returns (int56[] tickCumulatives, uint160[] secondsPerLiquidityCumulativeX128s)",
        ],
        provider,
    )

    const erc20 = [
        "function symbol() view returns (string)",
        "function decimals() view returns (uint8)",
        "function balanceOf(address) view returns (uint256)",
    ]
    const underlyingToken = new Contract(underlyingAddress, erc20, provider)
    const otherToken = new Contract(otherAddress, erc20, provider)

    let token0
    let token1
    let currentTick
    let underlyingSymbol
    let otherSymbol
    let underlyingDecimals
    let otherDecimals
    let strategyUnderlyingBalance
    let strategyOtherBalance

    try {
        ;[
            token0,
            token1,
            currentTick,
            underlyingSymbol,
            otherSymbol,
            underlyingDecimals,
            otherDecimals,
            strategyUnderlyingBalance,
            strategyOtherBalance,
        ] = await Promise.all([
            pool.token0(),
            pool.token1(),
            readValuationTick(pool, twapWindow),
            underlyingToken.symbol(),
            otherToken.symbol(),
            underlyingToken.decimals(),
            otherToken.decimals(),
            underlyingToken.balanceOf(strategyAddress),
            otherToken.balanceOf(strategyAddress),
        ])
    } catch (e) {
        console.error(`Failed reading pool/token state: ${e.message || e}`)
        process.exit(1)
    }

    const totalUnderlyingBalance = strategyUnderlyingBalance.add(assets)
    const underlyingStart = toNumberAmount(totalUnderlyingBalance, underlyingDecimals)
    const otherStart = toNumberAmount(strategyOtherBalance, otherDecimals)
    const otherIsToken0 = otherAddress.toLowerCase() === token0.toLowerCase()

    const ratioBps = computeOtherRatioBpsFromTicks({
        currentTick,
        tickLower: Number(tickLower.toString()),
        tickUpper: Number(tickUpper.toString()),
        token0,
        token1,
        underlying: underlyingAddress,
        other: otherAddress,
    })

    const ratio = ratioBps / 10000
    const priceToken1PerToken0 = Math.pow(1.0001, currentTick)

    const currentOtherValue = quoteOtherAsUnderlyingAtPrice(
        otherStart,
        priceToken1PerToken0,
        otherIsToken0,
    )
    const totalValue = underlyingStart + currentOtherValue
    const targetOtherValue = totalValue * ratio

    let expectedPrimarySwap = "none"
    let swapToOtherAmountIn = 0
    let swapToUnderlyingAmountIn = 0

    let underlyingAfterSwap = underlyingStart
    let otherAfterSwap = otherStart

    if (currentOtherValue < targetOtherValue) {
        expectedPrimarySwap = "underlying->other"
        const valueToSwap = targetOtherValue - currentOtherValue
        const otherOut = quoteUnderlyingAsOtherAtPrice(
            valueToSwap,
            priceToken1PerToken0,
            otherIsToken0,
        )
        swapToOtherAmountIn = valueToSwap
        underlyingAfterSwap -= valueToSwap
        otherAfterSwap += otherOut
    } else if (currentOtherValue > targetOtherValue) {
        expectedPrimarySwap = "other->underlying"
        const excessValue = currentOtherValue - targetOtherValue
        const otherToSwap = quoteUnderlyingAsOtherAtPrice(
            excessValue,
            priceToken1PerToken0,
            otherIsToken0,
        )
        const underlyingOut = quoteOtherAsUnderlyingAtPrice(
            otherToSwap,
            priceToken1PerToken0,
            otherIsToken0,
        )
        swapToUnderlyingAmountIn = otherToSwap
        otherAfterSwap -= otherToSwap
        underlyingAfterSwap += underlyingOut
    }

    if (underlyingAfterSwap < 0) underlyingAfterSwap = 0
    if (otherAfterSwap < 0) otherAfterSwap = 0

    const sqrtLower = getSqrtRatioApproxFromTick(Number(tickLower.toString()))
    const sqrtUpper = getSqrtRatioApproxFromTick(Number(tickUpper.toString()))
    const sqrtCurrent = getSqrtRatioApproxFromTick(currentTick)

    const amount0Balance =
        token0.toLowerCase() === underlyingAddress.toLowerCase()
            ? underlyingAfterSwap
            : otherAfterSwap
    const amount1Balance =
        token1.toLowerCase() === underlyingAddress.toLowerCase()
            ? underlyingAfterSwap
            : otherAfterSwap

    const { used0, used1 } = estimateLiquidityUse({
        sqrtCurrent,
        sqrtLower,
        sqrtUpper,
        amount0Balance,
        amount1Balance,
    })

    const estimatedUnderlyingAdded =
        token0.toLowerCase() === underlyingAddress.toLowerCase() ? used0 : used1
    const estimatedOtherAdded =
        token0.toLowerCase() === underlyingAddress.toLowerCase() ? used1 : used0

    const underlyingLeftover = Math.max(0, underlyingAfterSwap - estimatedUnderlyingAdded)
    const otherLeftover = Math.max(0, otherAfterSwap - estimatedOtherAdded)

    console.log("strategy:", strategyAddress)
    console.log("chain:", chainCfg.name)
    console.log("pool:", poolAddress)
    console.log("tickRange:", `${tickLower.toString()}..${tickUpper.toString()}`)
    console.log("valuationTick:", currentTick)
    console.log("twapWindow:", twapWindow.toString())
    console.log("")
    console.log("inputAssetsRaw:", assets.toString())
    console.log("inputAssets:", `${fmt(toNumberAmount(assets, underlyingDecimals), 6)} ${underlyingSymbol}`)
    console.log(
        "strategyBalancesBefore:",
        `${fmt(toNumberAmount(strategyUnderlyingBalance, underlyingDecimals), 6)} ${underlyingSymbol}, ${fmt(toNumberAmount(strategyOtherBalance, otherDecimals), 6)} ${otherSymbol}`,
    )
    console.log("")
    console.log("suggestedOtherRatioBps:", ratioBps)
    console.log("suggestedSwapToOtherBps:", 10000)
    console.log("suggestedSwapToUnderlyingBps:", 10000)
    console.log("expectedPrimarySwapDirection:", expectedPrimarySwap)
    console.log(
        "estimatedSwapIn:",
        `${fmt(swapToOtherAmountIn, 6)} ${underlyingSymbol} (toOther), ${fmt(swapToUnderlyingAmountIn, 6)} ${otherSymbol} (toUnderlying)`,
    )
    console.log("")
    console.log(
        "estimatedAddedToPosition:",
        `${fmt(estimatedUnderlyingAdded, 6)} ${underlyingSymbol} (~${rawEstimate(estimatedUnderlyingAdded, underlyingDecimals)} raw), ${fmt(estimatedOtherAdded, 6)} ${otherSymbol} (~${rawEstimate(estimatedOtherAdded, otherDecimals)} raw)`,
    )
    console.log(
        "estimatedPostMintLeftover:",
        `${fmt(underlyingLeftover, 6)} ${underlyingSymbol} (swept to vault), ${fmt(otherLeftover, 6)} ${otherSymbol} (can remain in strategy)`,
    )
    console.log("")
    console.log("note: estimate only; swap fees/slippage/price movement can change final amounts.")
}

main().catch((err) => {
    console.error(err)
    process.exit(1)
})
