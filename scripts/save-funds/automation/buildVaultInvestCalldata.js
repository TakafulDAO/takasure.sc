/*
Builds calldata for SFVault.investIntoStrategy(assets, strategies, payloads).

Example:
  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \
    --assets 1000000 \
    --strategies 0xStrat1,0xStrat2 \
    --payloads 0xdeadbeef,0x

Example (human-readable UniV3 action data, same payload for all strategies):
  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \
    --assets 1000000 \
    --strategies 0xStrat1 \
    --otherRatioBps 5000 \
    --swapToOtherBps 5000 \
    --swapToUnderlyingBps 5000 \
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
const OTHER_RATIO_AUTO_ALIASES = new Set(["auto", "best"])

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
            getArg(`${prefix}AmountOutMins`) ||
            getArg(`${prefix}Deadline`) ||
            getArg(`${prefix}Recipient`) ||
            getArg(`${prefix}RouteIds`),
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

function isAutoOtherRatio(value) {
    if (value === undefined || value === null) return false
    return OTHER_RATIO_AUTO_ALIASES.has(String(value).trim().toLowerCase())
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

function getSqrtRatioApproxFromTick(tick) {
    return Math.pow(1.0001, tick / 2)
}

function quoteOtherAsUnderlyingAtTick(otherAmount, tick, otherIsToken0) {
    if (!Number.isFinite(otherAmount) || otherAmount <= 0) return 0
    const priceToken1PerToken0 = Math.pow(1.0001, tick)
    if (!Number.isFinite(priceToken1PerToken0) || priceToken1PerToken0 <= 0) return 0
    return otherIsToken0 ? otherAmount * priceToken1PerToken0 : otherAmount / priceToken1PerToken0
}

function computeOtherRatioBpsFromSqrtPrice({
    sqrtPriceX96,
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
        return null
    }

    const otherIsToken0 = oth === t0

    // Convert exact sqrtPriceX96 to float (2^96 = 79228162514264337593543950336)
    const Q96 = 79228162514264337593543950336
    const p = Number(sqrtPriceX96.toString()) / Q96

    // Tick-based approximation is accurate for boundary ticks (integer values)
    const sa = getSqrtRatioApproxFromTick(tickLower)
    const sb = getSqrtRatioApproxFromTick(tickUpper)

    if (
        !(p > 0) ||
        !Number.isFinite(p) ||
        !(sa > 0) ||
        !(sb > 0) ||
        !Number.isFinite(sa) ||
        !Number.isFinite(sb)
    ) {
        return null
    }

    // Out-of-range: position is fully single-sided
    if (p <= sa) return otherIsToken0 ? 10000 : 0
    if (p >= sb) return otherIsToken0 ? 0 : 10000

    // Unit-liquidity token mix at spot price/range
    const amount0 = (sb - p) / (p * sb)
    const amount1 = p - sa
    const priceToken1PerToken0 = p * p

    let otherValueInUnderlying
    let totalValueInUnderlying
    if (otherIsToken0) {
        otherValueInUnderlying = amount0 * priceToken1PerToken0
        totalValueInUnderlying = amount1 + otherValueInUnderlying
    } else {
        otherValueInUnderlying = amount1 / priceToken1PerToken0
        totalValueInUnderlying = amount0 + otherValueInUnderlying
    }

    if (!(totalValueInUnderlying > 0) || !Number.isFinite(totalValueInUnderlying)) return null

    const ratio = otherValueInUnderlying / totalValueInUnderlying
    if (!Number.isFinite(ratio)) return null
    const bps = Math.round(ratio * 10000)
    return Math.max(0, Math.min(10000, bps))
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
        console.error("Failed to compute auto otherRatioBps: strategy/pool tokens mismatch")
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
        console.error("Failed to compute auto otherRatioBps: invalid sqrt ratios")
        process.exit(1)
    }

    // Out-of-range boundaries: position is single-sided.
    if (s <= sa) return otherIsToken0 ? 10000 : 0
    if (s >= sb) return otherIsToken0 ? 0 : 10000

    // Unit-liquidity token mix at current price/range:
    // amount0 = (sb - s) / (s * sb), amount1 = (s - sa)
    const amount0 = (sb - s) / (s * sb)
    const amount1 = s - sa
    const priceToken1PerToken0 = s * s

    let otherValueInUnderlying
    let totalValueInUnderlying

    if (otherIsToken0) {
        // other=token0, underlying=token1
        otherValueInUnderlying = amount0 * priceToken1PerToken0
        totalValueInUnderlying = amount1 + otherValueInUnderlying
    } else {
        // other=token1, underlying=token0
        otherValueInUnderlying = amount1 / priceToken1PerToken0
        totalValueInUnderlying = amount0 + otherValueInUnderlying
    }

    if (!(totalValueInUnderlying > 0) || !Number.isFinite(totalValueInUnderlying)) {
        return 0
    }

    const ratio = otherValueInUnderlying / totalValueInUnderlying
    if (!Number.isFinite(ratio)) return 0
    const bps = Math.round(ratio * 10000)
    if (bps < 0) return 0
    if (bps > 10000) return 10000
    return bps
}

async function resolveAutoOtherRatioBps(strategyAddress, chainCfg, assetsIncoming) {
    if (!chainCfg) {
        console.error("--otherRatioBps auto requires --chain")
        process.exit(1)
    }

    const rpcUrl = getRpcUrl(chainCfg)
    if (!rpcUrl) {
        if (chainCfg.name === "arb-one") {
            console.error(
                "Missing SAFE_RPC_URL or ARBITRUM_MAINNET_RPC_URL (required for --otherRatioBps auto)",
            )
            process.exit(1)
        }
        if (chainCfg.name === "arb-sepolia") {
            console.error(
                "Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL (required for --otherRatioBps auto)",
            )
            process.exit(1)
        }
        console.error("Missing RPC URL for selected --chain")
        process.exit(1)
    }

    const provider = new providers.JsonRpcProvider(rpcUrl)
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
    let underlying
    let other
    let twapWindow
    try {
        ;[poolAddress, tickLower, tickUpper, underlying, other, twapWindow] = await Promise.all([
            strategy.pool(),
            strategy.tickLower(),
            strategy.tickUpper(),
            strategy.asset(),
            strategy.otherToken(),
            strategy.twapWindow(),
        ])
    } catch (e) {
        console.error(`Failed to read strategy config for auto ratio: ${e.message || e}`)
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

    let token0
    let token1
    let sqrtPriceX96
    let slot0Tick
    try {
        ;[token0, token1] = await Promise.all([pool.token0(), pool.token1()])
        const slot0 = await pool.slot0()
        sqrtPriceX96 = slot0.sqrtPriceX96
        slot0Tick = Number(slot0.tick)
    } catch (e) {
        console.error(`Failed to read pool state for auto ratio: ${e.message || e}`)
        process.exit(1)
    }

    // Primary: use exact sqrtPriceX96 from slot0 — matches Uniswap UI fiat-value ratio.
    let ratioBps = computeOtherRatioBpsFromSqrtPrice({
        sqrtPriceX96,
        tickLower: Number(tickLower.toString()),
        tickUpper: Number(tickUpper.toString()),
        token0,
        token1,
        underlying,
        other,
    })

    // Fallback: tick-based formula (TWAP tick when configured, else spot tick).
    if (ratioBps === null) {
        let currentTick = slot0Tick
        const window = Number(twapWindow.toString())
        if (window > 0) {
            try {
                const [tickCumulatives] = await pool.observe([window, 0])
                const delta = Number(tickCumulatives[1].sub(tickCumulatives[0]).toString())
                currentTick = Math.trunc(delta / window)
                if (delta < 0 && delta % window !== 0) currentTick -= 1
            } catch {
                // ignore, use slot0Tick
            }
        }
        ratioBps = computeOtherRatioBpsFromTicks({
            currentTick,
            tickLower: Number(tickLower.toString()),
            tickUpper: Number(tickUpper.toString()),
            token0,
            token1,
            underlying,
            other,
        })
    }

    // Strategy contract only executes rebalancing swaps when otherRatioBps > 0.
    // If LP-optimal ratio is 0, we may still force 1bps only when current balances already
    // have >=1bps in otherToken value; this can help reduce legacy otherToken leftovers.
    if (ratioBps === 0) {
        const erc20 = [
            "function decimals() view returns (uint8)",
            "function balanceOf(address) view returns (uint256)",
        ]
        const underlyingToken = new Contract(underlying, erc20, provider)
        const otherToken = new Contract(other, erc20, provider)

        let underlyingDecimals
        let otherDecimals
        let strategyUnderlyingBal
        let strategyOtherBal
        try {
            ;[underlyingDecimals, otherDecimals, strategyUnderlyingBal, strategyOtherBal] =
                await Promise.all([
                    underlyingToken.decimals(),
                    otherToken.decimals(),
                    underlyingToken.balanceOf(strategyAddress),
                    otherToken.balanceOf(strategyAddress),
                ])
        } catch (e) {
            console.error(`Failed to read token balances for auto ratio: ${e.message || e}`)
            process.exit(1)
        }

        const incoming = assetsIncoming || BigNumber.from(0)
        const underlyingTotal = Number(
            utils.formatUnits(strategyUnderlyingBal.add(incoming), underlyingDecimals),
        )
        const otherBalance = Number(utils.formatUnits(strategyOtherBal, otherDecimals))
        const otherIsToken0 = other.toLowerCase() === token0.toLowerCase()
        const otherValueInUnderlying = quoteOtherAsUnderlyingAtTick(
            otherBalance,
            slot0Tick,
            otherIsToken0,
        )
        const totalValueInUnderlying = underlyingTotal + otherValueInUnderlying
        const currentOtherRatioBps =
            totalValueInUnderlying > 0 && Number.isFinite(totalValueInUnderlying)
                ? (otherValueInUnderlying / totalValueInUnderlying) * 10000
                : 0

        if (currentOtherRatioBps >= 1) {
            ratioBps = 1
            console.log(
                "autoOtherRatioBpsAdjusted:",
                "1",
                "(forced from 0 to trigger cleanup swap toward underlying)",
            )
        }
    }

    console.log("autoOtherRatioBps:", ratioBps)
    return BigNumber.from(ratioBps)
}

function buildSwapData(prefix, defaultRecipient, chainCfg, defaultFee) {
    const dataRaw = getArg(`${prefix}Data`)
    if (dataRaw) return dataRaw

    const bps = getArg(`${prefix}Bps`)
    const amountInRaw = getArg(`${prefix}AmountIn`)
    const amountOutMinRaw = getArg(`${prefix}AmountOutMin`)
    const amountOutMinsRaw = parseList(getArg(`${prefix}AmountOutMins`), `${prefix}AmountOutMins`)
    const deadlineRaw = getArg(`${prefix}Deadline`)
    const routeIdsRaw = parseList(getArg(`${prefix}RouteIds`), `${prefix}RouteIds`)
    const hasLegacyHints = Boolean(
        getArg(`${prefix}TokenIn`) ||
            getArg(`${prefix}TokenOut`) ||
            getArg(`${prefix}Fee`) ||
            getArg(`${prefix}Recipient`) ||
            defaultRecipient ||
            chainCfg ||
            defaultFee,
    )

    // No builder inputs
    if (!bps && !amountInRaw && !amountOutMinRaw && !deadlineRaw && !hasLegacyHints) return "0x"

    if (!bps && !amountInRaw) {
        console.error(`${prefix}: either bps or amountIn is required`)
        process.exit(1)
    }

    if (bps && amountInRaw) {
        console.error(`${prefix}: provide either bps or amountIn (not both)`)
        process.exit(1)
    }

    const amountOutMin = parseUint(amountOutMinRaw || "0", `${prefix}AmountOutMin`)
    const deadline = parseUint(deadlineRaw || "0", `${prefix}Deadline`)

    let amountIn
    if (amountInRaw) {
        amountIn = parseUint(amountInRaw, `${prefix}AmountIn`)
    } else {
        const AMOUNT_IN_BPS_FLAG = BigNumber.from(1).shl(255)
        amountIn = AMOUNT_IN_BPS_FLAG.or(parseBps(bps, `${prefix}Bps`))
    }

    const routeIds = routeIdsRaw
        ? routeIdsRaw.map((value) => {
              const routeId = Number(value)
              if (!Number.isFinite(routeId) || routeId < 1 || routeId > 2) {
                  console.error(`${prefix}RouteIds entries must be between 1 and 2`)
                  process.exit(1)
              }
              return routeId
          })
        : [1, 2]

    if (new Set(routeIds).size !== routeIds.length) {
        console.error(`${prefix}RouteIds must not contain duplicates`)
        process.exit(1)
    }
    if (routeIds.length === 0 || routeIds.length > 2) {
        console.error(`${prefix}RouteIds must contain between 1 and 2 entries`)
        process.exit(1)
    }

    const amountOutMinsFixed = [amountOutMin, BigNumber.from(0)]
    if (amountOutMinsRaw) {
        if (amountOutMinRaw) {
            console.error(`${prefix}: provide either amountOutMin or amountOutMins (not both)`)
            process.exit(1)
        }
        if (amountOutMinsRaw.length !== routeIds.length) {
            console.error(`${prefix}AmountOutMins must match ${prefix}RouteIds length`)
            process.exit(1)
        }
        for (let i = 0; i < amountOutMinsRaw.length; i++) {
            amountOutMinsFixed[i] = parseUint(amountOutMinsRaw[i], `${prefix}AmountOutMins`)
        }
    }

    const routeIdsFixed = [0, 0]
    for (let i = 0; i < routeIds.length; i++) routeIdsFixed[i] = routeIds[i]

    return utils.defaultAbiCoder.encode(
        ["uint256", "uint256", "uint8", "uint8[2]", "uint256[2]"],
        [amountIn, deadline, routeIds.length, routeIdsFixed, amountOutMinsFixed],
    )
}

async function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js --assets <uint|full|max|all> [--strategies <addr1,addr2>] [--payloads <0x...,0x...>] [--chain <arb-one|arb-sepolia>]",
                "  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js --assets <uint|full|max|all> [--strategies <addr|uniV3>] --otherRatioBps <bps|auto> \\",
                "    --swapToOtherBps <bps> --swapToUnderlyingBps <bps> \\",
                "    [--pmDeadline <uint>] [--minUnderlying <uint>] [--minOther <uint>]",
                "",
                "Examples:",
                "  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \\",
                "    --assets 1000000 \\",
                "    --strategies 0xStrat1,0xStrat2 \\",
                "    --payloads 0xdeadbeef,0x",
                "  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \\",
                "    --assets 1000000 \\",
                "    --strategies uniV3 --chain arb-one \\",
                "    --otherRatioBps 5000 \\",
                "    --swapToOtherBps 5000 \\",
                "    --swapToUnderlyingBps 5000 \\",
                "    --pmDeadline 0",
                "  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \\",
                "    --assets full",
                "",
                "Flags",
                "  --assets <uint|full|max|all>     Amount of underlying to invest; full/max/all = SFVault.idleAssets().",
                "  --chain <arb-one|arb-sepolia>    Chain shortcut for defaults. Defaults to arb-one.",
                "  --sendToSafe                    Propose tx to the Arbitrum One Safe (requires --chain arb-one).",
                "  --sendTx                        Send tx onchain for Arbitrum Sepolia (requires --chain arb-sepolia).",
                "  --simulateTenderly              Simulate on Tenderly before sending (arb-one only).",
                "  --tenderlyGas <uint>            Gas limit override for Tenderly simulation.",
                "  --tenderlyBlock <uint|latest>   Block number for Tenderly simulation.",
                "  --tenderlySimulationType <str>  Optional Tenderly simulation type.",
                "  --minOther <uint>                Min other token out for PM actions.",
                "  --minUnderlying <uint>           Min underlying out for PM actions.",
                "  --otherRatioBps <bps|auto>       Target otherToken ratio (0..10000) or auto LP-target ratio (best-effort cleanup).",
                "  --payloads <p1,p2>               Per-strategy payloads (hex). Length must match strategies.",
                "  --pmDeadline <uint>              PM deadline (0 = sentinel).",
                "  --strategies <a,b>               Strategy addresses (or uniV3). Defaults to uniV3.",
                "  --swapToOtherAmountIn <uint>     Swap input amount for otherToken path (absolute).",
                "  --swapToOtherAmountOutMin <uint> Swap min out for otherToken path.",
                "  --swapToOtherBps <bps>           Swap input amount as BPS sentinel (0..10000).",
                "  --swapToOtherData <0x>           Raw compact swapToOtherData bytes (overrides builder).",
                "  --swapToOtherDeadline <uint>     Swap deadline for otherToken path.",
                "  --swapToUnderlyingAmountIn <uint>   Swap input amount for underlying path (absolute).",
                "  --swapToUnderlyingAmountOutMin <uint> Swap min out for underlying path.",
                "  --swapToUnderlyingBps <bps>      Swap input amount as BPS sentinel (0..10000).",
                "  --swapToUnderlyingData <0x>      Raw compact swapToUnderlyingData bytes (overrides builder).",
                "  --swapToUnderlyingDeadline <uint>   Swap deadline for underlying path.",
                "  Deprecated compatibility flags such as --swapTo*TokenIn/Out, --swapTo*Fee and --swapTo*Recipient are ignored by the builder.",
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

            const otherRatioArg = getArg("otherRatioBps", "0")
            let otherRatioBps
            if (isAutoOtherRatio(otherRatioArg)) {
                if (strategies.length !== 1) {
                    console.error("--otherRatioBps auto supports a single strategy")
                    process.exit(1)
                }
                otherRatioBps = await resolveAutoOtherRatioBps(strategies[0], chainCfg, assets)
            } else {
                otherRatioBps = parseBps(otherRatioArg, "otherRatioBps")
            }
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
node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \
  --chain arb-one \
  --assets 300000000 \
  --strategies uniV3 \
  --otherRatioBps 5150 \
  --assets full \
  --otherRatioBps auto \
  --swapToOtherBps 10000 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly \
  --sendToSafe

===========================================================================

node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \
  --assets full \
  --otherRatioBps auto \
  --swapToOtherBps 10000 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly \
  --sendToSafe

  node scripts/save-funds/automation/javascript/buildVaultInvestCalldata.js \
  --chain arb-one \
  --assets 300000000 \
  --strategies uniV3 \
  --otherRatioBps 1 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly \
  --sendToSafe
*/

/*
POOL=0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6
cast call --rpc-url $ARBITRUM_MAINNET_RPC_URL $POOL "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
*/
