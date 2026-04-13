const { BigNumber, Contract, providers, utils } = require("ethers")
const { loadDeploymentAddress } = require("./chainConfig")
const {
    extractSimulationAssetChanges,
    extractSimulationBlockNumber,
    extractSimulationLogs,
    extractSimulationTimestamp,
} = require("./tenderlySimulate")

const ZERO = BigNumber.from(0)
const DEFAULT_PM_DEADLINE_SECONDS = 300

const SAFE_APP_CHAIN_PREFIX = {
    "arb-one": "arb1",
}

const UNISWAP_APP_CHAIN_SLUG = {
    "arb-one": "arbitrum",
}

const UNISWAP_V3_POSITION_MANAGER = {
    "arb-one": "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
}

const STRATEGY_EVENT_IFACE = new utils.Interface([
    "event OnPositionCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1)",
    "event OnPositionMinted(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)",
    "event OnPositionRebalanced(uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper)",
    "event OnSwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)",
    "event OnTickRangeUpdated(int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper)",
])

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

function parseDiscordNotificationFlags(argv = process.argv) {
    const wantsDiscordNotification = argv.includes("--discordNotification")
    const wantsDeprecatedAlias = argv.includes("--discorNotification")
    return {
        wantsDiscordNotification: wantsDiscordNotification || wantsDeprecatedAlias,
        usedDeprecatedAlias: wantsDeprecatedAlias && !wantsDiscordNotification,
    }
}

function toChecksum(address, label) {
    try {
        return utils.getAddress(address)
    } catch (err) {
        throw new Error(`Invalid ${label}: ${address}`)
    }
}

function toInt(value, label) {
    const num = BigNumber.isBigNumber(value) ? value.toNumber() : Number(value)
    if (!Number.isFinite(num)) {
        throw new Error(`Invalid ${label}`)
    }
    return num
}

function parseNotificationUint(value, label) {
    try {
        return BigNumber.from(value || 0)
    } catch (err) {
        throw new Error(`Invalid ${label}`)
    }
}

function zeroTokenAmounts(extra = {}) {
    return {
        underlying: ZERO,
        other: ZERO,
        ...extra,
    }
}

function hasNonZeroTokenAmounts(amounts) {
    return amounts.underlying.gt(0) || amounts.other.gt(0)
}

function getPositionManagerAddress(chainName) {
    const address = UNISWAP_V3_POSITION_MANAGER[chainName]
    if (!address) {
        throw new Error(`Missing Uniswap V3 PositionManager address for ${chainName}`)
    }
    return toChecksum(address, "Uniswap V3 PositionManager")
}

function ensureNotificationSupported({ wantsDiscordNotification, chainCfg, wantsSendTx }) {
    if (!wantsDiscordNotification) return
    if (!chainCfg || chainCfg.name !== "arb-one") {
        throw new Error("--discordNotification is only supported for --chain arb-one")
    }
    if (wantsSendTx) {
        throw new Error("--discordNotification is not supported together with --sendTx")
    }
    if (!process.env.DISCORD_WEBHOOK_URL) {
        throw new Error("Missing DISCORD_WEBHOOK_URL (required for --discordNotification)")
    }
}

function decodeNotificationBundle(data) {
    if (!data || data === "0x") {
        throw new Error(
            "Discord notification requires an explicit single-strategy rebalance bundle; raw --data 0x is not supported",
        )
    }

    let strategies
    let payloads
    try {
        ;[strategies, payloads] = utils.defaultAbiCoder.decode(["address[]", "bytes[]"], data)
    } catch (err) {
        throw new Error(
            "Discord notification requires rebalance data encoded as abi.encode(address[], bytes[])",
        )
    }

    if (!Array.isArray(strategies) || !Array.isArray(payloads) || strategies.length !== payloads.length) {
        throw new Error("Discord notification requires valid rebalance bundle arrays")
    }
    if (strategies.length !== 1) {
        throw new Error(
            "Discord notification currently supports exactly one strategy in the rebalance bundle",
        )
    }
    if (!payloads[0] || payloads[0] === "0x") {
        throw new Error(
            "Discord notification requires a non-empty UniV3 rebalance payload; empty payload bundles are not supported",
        )
    }

    return {
        strategyAddress: toChecksum(strategies[0], "strategy address"),
        payload: payloads[0],
    }
}

function decodeRebalancePayload(payload) {
    const payloadBytes = utils.arrayify(payload)
    if (payloadBytes.length === 160) {
        const [newTickLower, newTickUpper, pmDeadlineRaw, minUnderlying, minOther] =
            utils.defaultAbiCoder.decode(
                ["int24", "int24", "uint256", "uint256", "uint256"],
                payload,
            )
        return {
            encoding: "legacy",
            actionDataProvided: false,
            newTickLower: toInt(newTickLower, "tickLower"),
            newTickUpper: toInt(newTickUpper, "tickUpper"),
            pmDeadlineRaw: parseNotificationUint(pmDeadlineRaw, "pmDeadline"),
            minUnderlying: parseNotificationUint(minUnderlying, "minUnderlying"),
            minOther: parseNotificationUint(minOther, "minOther"),
            otherRatioBps: ZERO,
            swapToOtherData: "0x",
            swapToUnderlyingData: "0x",
        }
    }

    let decoded
    try {
        decoded = utils.defaultAbiCoder.decode(["int24", "int24", "bytes"], payload)
    } catch (err) {
        throw new Error("Discord notification could not decode the UniV3 rebalance payload")
    }

    const [newTickLower, newTickUpper, actionDataRaw] = decoded
    const actionDataProvided = Boolean(actionDataRaw && actionDataRaw !== "0x")

    let otherRatioBps = ZERO
    let swapToOtherData = "0x"
    let swapToUnderlyingData = "0x"
    let pmDeadlineRaw = ZERO
    let minUnderlying = ZERO
    let minOther = ZERO

    if (actionDataProvided) {
        let actionData
        try {
            actionData = utils.defaultAbiCoder.decode(
                ["uint16", "bytes", "bytes", "uint256", "uint256", "uint256"],
                actionDataRaw,
            )
        } catch (err) {
            throw new Error("Discord notification could not decode UniV3 rebalance actionData")
        }
        ;[
            otherRatioBps,
            swapToOtherData,
            swapToUnderlyingData,
            pmDeadlineRaw,
            minUnderlying,
            minOther,
        ] = actionData
    }

    return {
        encoding: "new",
        actionDataProvided,
        newTickLower: toInt(newTickLower, "tickLower"),
        newTickUpper: toInt(newTickUpper, "tickUpper"),
        pmDeadlineRaw: parseNotificationUint(pmDeadlineRaw, "pmDeadline"),
        minUnderlying: parseNotificationUint(minUnderlying, "minUnderlying"),
        minOther: parseNotificationUint(minOther, "minOther"),
        otherRatioBps: parseNotificationUint(otherRatioBps, "otherRatioBps"),
        swapToOtherData,
        swapToUnderlyingData,
    }
}

function decodeSingleStrategyRebalancePlan({ chainCfg, data }) {
    if (!chainCfg) {
        throw new Error("Discord notification requires a chain config")
    }

    const bundle = decodeNotificationBundle(data)
    const uniV3StrategyAddress = toChecksum(
        loadDeploymentAddress(chainCfg, "SFUniswapV3Strategy"),
        "SFUniswapV3Strategy deployment",
    )

    if (bundle.strategyAddress !== uniV3StrategyAddress) {
        throw new Error(
            "Discord notification v1 only supports the configured SFUniswapV3Strategy rebalance flow",
        )
    }

    return {
        ...bundle,
        ...decodeRebalancePayload(bundle.payload),
    }
}

async function readStrategyPreState({ chainCfg, strategyAddress }) {
    const rpcUrl = getRpcUrl(chainCfg)
    if (!rpcUrl) {
        if (chainCfg.name === "arb-one") {
            throw new Error("Missing SAFE_RPC_URL or ARBITRUM_MAINNET_RPC_URL")
        }
        throw new Error("Missing RPC URL for notification pre-state reads")
    }

    const provider = new providers.JsonRpcProvider(rpcUrl)
    const strategy = new Contract(
        strategyAddress,
        [
            "function asset() view returns (address)",
            "function otherToken() view returns (address)",
            "function vault() view returns (address)",
            "function pool() view returns (address)",
            "function positionTokenId() view returns (uint256)",
            "function tickLower() view returns (int24)",
            "function tickUpper() view returns (int24)",
        ],
        provider,
    )

    let underlyingAddress
    let otherAddress
    let vaultAddress
    let poolAddress
    let positionTokenId
    let tickLower
    let tickUpper
    try {
        ;[
            underlyingAddress,
            otherAddress,
            vaultAddress,
            poolAddress,
            positionTokenId,
            tickLower,
            tickUpper,
        ] = await Promise.all([
            strategy.asset(),
            strategy.otherToken(),
            strategy.vault(),
            strategy.pool(),
            strategy.positionTokenId(),
            strategy.tickLower(),
            strategy.tickUpper(),
        ])
    } catch (err) {
        throw new Error(`Failed to read strategy notification pre-state: ${err.message || err}`)
    }

    const pool = new Contract(
        poolAddress,
        [
            "function token0() view returns (address)",
            "function token1() view returns (address)",
            "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
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
    let underlyingSymbol
    let otherSymbol
    let underlyingDecimals
    let otherDecimals
    let underlyingBalance
    let otherBalance
    let currentPositionUnderlying = ZERO
    let currentPositionOther = ZERO
    try {
        ;[
            token0,
            token1,
            underlyingSymbol,
            otherSymbol,
            underlyingDecimals,
            otherDecimals,
            underlyingBalance,
            otherBalance,
        ] = await Promise.all([
            pool.token0(),
            pool.token1(),
            underlyingToken.symbol(),
            otherToken.symbol(),
            underlyingToken.decimals(),
            otherToken.decimals(),
            underlyingToken.balanceOf(strategyAddress),
            otherToken.balanceOf(strategyAddress),
        ])
    } catch (err) {
        throw new Error(`Failed to read token notification pre-state: ${err.message || err}`)
    }

    if (BigNumber.from(positionTokenId || 0).gt(0)) {
        const positionManagerAddress = getPositionManagerAddress(chainCfg.name)
        const mathHelperAddress = loadDeploymentAddress(chainCfg, "UniswapV3MathHelper")

        const positionManager = new Contract(
            positionManagerAddress,
            [
                "function positions(uint256 tokenId) view returns (uint96 nonce, address operator, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, uint128 tokensOwed0, uint128 tokensOwed1)",
            ],
            provider,
        )
        const mathHelper = new Contract(
            mathHelperAddress,
            [
                "function getSqrtRatioAtTick(int24 tick) view returns (uint160)",
                "function getAmountsForLiquidity(uint160 sqrtRatioX96, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity) view returns (uint256 amount0, uint256 amount1)",
            ],
            provider,
        )

        try {
            const [slot0, position] = await Promise.all([
                pool.slot0(),
                positionManager.positions(positionTokenId),
            ])

            const liquidity = parseNotificationUint(position.liquidity, "position liquidity")
            if (liquidity.gt(0)) {
                const positionToken0 = toChecksum(position.token0, "position token0")
                const positionToken1 = toChecksum(position.token1, "position token1")
                if (
                    positionToken0.toLowerCase() !== String(token0).toLowerCase() ||
                    positionToken1.toLowerCase() !== String(token1).toLowerCase()
                ) {
                    throw new Error("position token ordering does not match the configured pool")
                }

                const [sqrtLower, sqrtUpper] = await Promise.all([
                    mathHelper.getSqrtRatioAtTick(toInt(position.tickLower, "position tickLower")),
                    mathHelper.getSqrtRatioAtTick(toInt(position.tickUpper, "position tickUpper")),
                ])
                const [amount0, amount1] = await mathHelper.getAmountsForLiquidity(
                    slot0.sqrtPriceX96 || slot0[0],
                    sqrtLower,
                    sqrtUpper,
                    liquidity,
                )
                const livePosition = poolAmountsToTokenAmounts(amount0, amount1, {
                    token0Address: toChecksum(token0, "pool token0"),
                    underlyingAddress: toChecksum(underlyingAddress, "underlying token"),
                })
                currentPositionUnderlying = livePosition.underlying
                currentPositionOther = livePosition.other
            }
        } catch (err) {
            throw new Error(
                `Failed to read live position notification pre-state: ${err.message || err}`,
            )
        }
    }

    return {
        provider,
        chainName: chainCfg.name,
        strategyAddress: toChecksum(strategyAddress, "strategy address"),
        vaultAddress: toChecksum(vaultAddress, "vault address"),
        poolAddress: toChecksum(poolAddress, "pool address"),
        underlyingAddress: toChecksum(underlyingAddress, "underlying token"),
        otherAddress: toChecksum(otherAddress, "other token"),
        token0Address: toChecksum(token0, "pool token0"),
        token1Address: toChecksum(token1, "pool token1"),
        underlyingSymbol,
        otherSymbol,
        underlyingDecimals: Number(underlyingDecimals),
        otherDecimals: Number(otherDecimals),
        underlyingBalance,
        otherBalance,
        currentPositionUnderlying,
        currentPositionOther,
        positionTokenId: parseNotificationUint(positionTokenId, "positionTokenId"),
        tickLower: toInt(tickLower, "tickLower"),
        tickUpper: toInt(tickUpper, "tickUpper"),
    }
}

function normalizeLog(rawLog, index) {
    if (!rawLog) return null
    const address =
        rawLog.address ||
        rawLog.contract_address ||
        rawLog.contractAddress ||
        rawLog.raw?.address ||
        rawLog.raw?.contract_address
    const topics = rawLog.topics || rawLog.raw?.topics
    const data = rawLog.data || rawLog.raw?.data

    if (!address || !Array.isArray(topics) || typeof data !== "string") return null

    return {
        address: address.toLowerCase(),
        topics,
        data,
        logIndex:
            rawLog.logIndex ??
            rawLog.log_index ??
            rawLog.index ??
            rawLog.raw?.logIndex ??
            rawLog.raw?.log_index ??
            index,
    }
}

function parseStrategyEvents(simulation, strategyAddress) {
    const rawLogs = extractSimulationLogs(simulation)
    if (!Array.isArray(rawLogs) || rawLogs.length === 0) return []

    const address = strategyAddress.toLowerCase()
    return rawLogs
        .map((log, index) => normalizeLog(log, index))
        .filter(Boolean)
        .filter((log) => log.address === address)
        .sort((a, b) => Number(a.logIndex) - Number(b.logIndex))
        .flatMap((log) => {
            try {
                const parsed = STRATEGY_EVENT_IFACE.parseLog({ topics: log.topics, data: log.data })
                return [
                    {
                        name: parsed.name,
                        args: parsed.args,
                        logIndex: Number(log.logIndex),
                    },
                ]
            } catch (err) {
                return []
            }
        })
}

function normalizeAssetChange(change, index) {
    if (!change) return null
    const tokenInfo = change.token_info || change.assetInfo || change.asset_info || {}
    const standard = tokenInfo.standard || change.standard || ""
    const contractAddress =
        tokenInfo.contract_address ||
        tokenInfo.contractAddress ||
        change.contract_address ||
        change.contractAddress ||
        null
    const rawAmount = change.raw_amount ?? change.rawAmount ?? change.amount ?? "0"

    let rawAmountBn
    try {
        rawAmountBn = BigNumber.from(String(rawAmount))
    } catch (err) {
        rawAmountBn = ZERO
    }

    let tokenId = null
    const rawTokenId =
        change.token_id ??
        change.tokenId ??
        tokenInfo.token_id ??
        tokenInfo.tokenId ??
        change.nft_id ??
        change.nftId ??
        null
    if (rawTokenId !== null && rawTokenId !== undefined) {
        try {
            tokenId = BigNumber.from(String(rawTokenId))
        } catch (err) {
            tokenId = null
        }
    }

    return {
        index,
        type: String(change.type || "").toLowerCase(),
        standard: String(standard || "").toUpperCase(),
        contractAddress: contractAddress ? contractAddress.toLowerCase() : null,
        symbol: tokenInfo.symbol || change.symbol || "",
        from: change.from ? String(change.from).toLowerCase() : null,
        to: change.to ? String(change.to).toLowerCase() : null,
        rawAmount: rawAmountBn,
        tokenId,
    }
}

function normalizeAssetChanges(simulation) {
    const raw = extractSimulationAssetChanges(simulation)
    if (!Array.isArray(raw)) {
        throw new Error("Tenderly simulation is missing transaction.transaction_info.asset_changes")
    }
    return raw.map((change, index) => normalizeAssetChange(change, index)).filter(Boolean)
}

function poolAmountsToTokenAmounts(amount0, amount1, preState) {
    if (preState.token0Address.toLowerCase() === preState.underlyingAddress.toLowerCase()) {
        return {
            underlying: parseNotificationUint(amount0, "amount0"),
            other: parseNotificationUint(amount1, "amount1"),
        }
    }
    return {
        underlying: parseNotificationUint(amount1, "amount1"),
        other: parseNotificationUint(amount0, "amount0"),
    }
}

function deriveCollectedPositionFromAssetChanges(assetChanges, preState) {
    const strategy = preState.strategyAddress.toLowerCase()
    const underlying = preState.underlyingAddress.toLowerCase()
    const other = preState.otherAddress.toLowerCase()
    let started = false
    let totalUnderlying = ZERO
    let totalOther = ZERO

    for (const change of assetChanges) {
        if (change.standard !== "ERC20") continue
        if (change.to !== strategy && change.from !== strategy) continue
        if (change.contractAddress !== underlying && change.contractAddress !== other) continue

        if (!started) {
            if (change.to === strategy) {
                started = true
            } else {
                continue
            }
        }

        if (change.from === strategy) break

        if (change.contractAddress === underlying) {
            totalUnderlying = totalUnderlying.add(change.rawAmount)
        } else {
            totalOther = totalOther.add(change.rawAmount)
        }
    }

    return { underlying: totalUnderlying, other: totalOther, inferred: true }
}

function deriveNewPositionFromAssetChanges(assetChanges, preState) {
    const strategy = preState.strategyAddress.toLowerCase()
    const underlying = preState.underlyingAddress.toLowerCase()
    const other = preState.otherAddress.toLowerCase()
    const vault = preState.vaultAddress.toLowerCase()
    const positionManager = getPositionManagerAddress(preState.chainName).toLowerCase()
    const mintChange = [...assetChanges]
        .reverse()
        .find(
            (change) =>
                change.standard === "ERC721" &&
                change.type === "mint" &&
                change.contractAddress === positionManager &&
                change.to === vault,
        )

    if (!mintChange) return null

    let totalUnderlying = ZERO
    let totalOther = ZERO
    let collecting = false

    for (let i = mintChange.index - 1; i >= 0; --i) {
        const change = assetChanges[i]
        if (
            change.standard === "ERC20" &&
            change.from === strategy &&
            (change.contractAddress === underlying || change.contractAddress === other)
        ) {
            collecting = true
            if (change.contractAddress === underlying) {
                totalUnderlying = totalUnderlying.add(change.rawAmount)
            } else {
                totalOther = totalOther.add(change.rawAmount)
            }
            continue
        }
        if (collecting) break
    }

    return {
        underlying: totalUnderlying,
        other: totalOther,
        tokenId: mintChange.tokenId,
        tickLower: null,
        tickUpper: null,
        inferred: true,
    }
}

function deriveCollectedPosition(events, assetChanges, preState) {
    const collectedEvent = events.find((event) => event.name === "OnPositionCollected")
    if (collectedEvent) {
        return {
            ...poolAmountsToTokenAmounts(
                collectedEvent.args.amount0,
                collectedEvent.args.amount1,
                preState,
            ),
            inferred: false,
        }
    }

    if (preState.positionTokenId.gt(0)) {
        const fallback = deriveCollectedPositionFromAssetChanges(assetChanges, preState)
        if (fallback.underlying.gt(0) || fallback.other.gt(0)) return fallback
        throw new Error(
            "Tenderly simulation did not expose enough data to derive the collected exit amounts",
        )
    }

    return zeroTokenAmounts({ inferred: false })
}

function deriveDisplayedCurrentPosition(preState, collectedPosition) {
    if (
        preState.currentPositionUnderlying !== undefined &&
        preState.currentPositionOther !== undefined
    ) {
        return {
            underlying: parseNotificationUint(
                preState.currentPositionUnderlying,
                "currentPositionUnderlying",
            ),
            other: parseNotificationUint(preState.currentPositionOther, "currentPositionOther"),
            inferred: false,
        }
    }

    if (preState.positionTokenId.gt(0)) {
        return {
            underlying: collectedPosition.underlying,
            other: collectedPosition.other,
            inferred: true,
        }
    }

    return zeroTokenAmounts({ inferred: false })
}

function deriveNewPosition(events, assetChanges, preState) {
    const mintedEvent = [...events].reverse().find((event) => event.name === "OnPositionMinted")
    if (mintedEvent) {
        return {
            ...poolAmountsToTokenAmounts(
                mintedEvent.args.amount0,
                mintedEvent.args.amount1,
                preState,
            ),
            tokenId: parseNotificationUint(mintedEvent.args.tokenId, "new tokenId"),
            tickLower: toInt(mintedEvent.args.tickLower, "mint tickLower"),
            tickUpper: toInt(mintedEvent.args.tickUpper, "mint tickUpper"),
            inferred: false,
        }
    }

    const fallback = deriveNewPositionFromAssetChanges(assetChanges, preState)
    if (fallback) return fallback
    if (preState.positionTokenId.gt(0)) {
        throw new Error("Tenderly simulation did not expose enough data to derive the new position")
    }
    return {
        ...zeroTokenAmounts({ inferred: true }),
        tokenId: null,
        tickLower: null,
        tickUpper: null,
    }
}

function deriveSwapTotalsFromEvents(events, preState) {
    const totals = {
        underlyingIn: ZERO,
        underlyingOut: ZERO,
        otherIn: ZERO,
        otherOut: ZERO,
    }

    for (const event of events) {
        if (event.name !== "OnSwapExecuted") continue
        const tokenIn = String(event.args.tokenIn).toLowerCase()
        const tokenOut = String(event.args.tokenOut).toLowerCase()
        const amountIn = parseNotificationUint(event.args.amountIn, "swap amountIn")
        const amountOut = parseNotificationUint(event.args.amountOut, "swap amountOut")

        if (tokenIn === preState.underlyingAddress.toLowerCase()) {
            totals.underlyingIn = totals.underlyingIn.add(amountIn)
        }
        if (tokenIn === preState.otherAddress.toLowerCase()) {
            totals.otherIn = totals.otherIn.add(amountIn)
        }
        if (tokenOut === preState.underlyingAddress.toLowerCase()) {
            totals.underlyingOut = totals.underlyingOut.add(amountOut)
        }
        if (tokenOut === preState.otherAddress.toLowerCase()) {
            totals.otherOut = totals.otherOut.add(amountOut)
        }
    }

    const totalGiven = totals.underlyingIn.add(totals.otherIn)
    const totalReceived = totals.underlyingOut.add(totals.otherOut)

    return {
        ...totals,
        totalGiven,
        totalReceived,
        netCost: totalGiven.gte(totalReceived)
            ? totalGiven.sub(totalReceived)
            : totalReceived.sub(totalGiven),
        netDirection: totalGiven.gte(totalReceived) ? "cost" : "gain",
    }
}

function deriveRemainingsFromAssetChanges(assetChanges, preState) {
    const strategy = preState.strategyAddress.toLowerCase()
    const vault = preState.vaultAddress.toLowerCase()
    const underlying = preState.underlyingAddress.toLowerCase()
    const other = preState.otherAddress.toLowerCase()

    const sweptUnderlying = assetChanges
        .filter(
            (change) =>
                change.standard === "ERC20" &&
                change.contractAddress === underlying &&
                change.from === strategy &&
                change.to === vault,
        )
        .reduce((sum, change) => sum.add(change.rawAmount), ZERO)

    const remainingOther = assetChanges
        .filter(
            (change) =>
                change.standard === "ERC20" &&
                change.contractAddress === other &&
                (change.from === strategy || change.to === strategy),
        )
        .reduce((sum, change) => {
            if (change.to === strategy) return sum.add(change.rawAmount)
            return bnSubChecked("asset change other delta", sum, change.rawAmount)
        }, preState.otherBalance)

    return { sweptUnderlying, remainingOther }
}

function deriveSwapTotalsFromAccounting({
    preState,
    collectedPosition,
    newPosition,
    sweptUnderlying,
    remainingOther,
}) {
    const underlyingAvailable = preState.underlyingBalance.add(collectedPosition.underlying)
    const underlyingConsumed = newPosition.underlying.add(sweptUnderlying)
    const otherAvailable = preState.otherBalance.add(collectedPosition.other)
    const otherConsumed = newPosition.other.add(remainingOther)

    const underlyingSpent = underlyingAvailable.gte(underlyingConsumed)
        ? underlyingAvailable.sub(underlyingConsumed)
        : ZERO
    const underlyingReceived = underlyingConsumed.gt(underlyingAvailable)
        ? underlyingConsumed.sub(underlyingAvailable)
        : ZERO
    const otherSpent = otherAvailable.gte(otherConsumed) ? otherAvailable.sub(otherConsumed) : ZERO
    const otherReceived = otherConsumed.gt(otherAvailable) ? otherConsumed.sub(otherAvailable) : ZERO

    if (
        underlyingSpent.isZero() &&
        underlyingReceived.isZero() &&
        otherSpent.isZero() &&
        otherReceived.isZero()
    ) {
        return {
            underlyingIn: ZERO,
            underlyingOut: ZERO,
            otherIn: ZERO,
            otherOut: ZERO,
            totalGiven: ZERO,
            totalReceived: ZERO,
            netCost: ZERO,
            netDirection: "cost",
            inferred: true,
        }
    }

    if (
        underlyingSpent.gt(0) &&
        otherReceived.gt(0) &&
        underlyingReceived.isZero() &&
        otherSpent.isZero()
    ) {
        const totalGiven = underlyingSpent
        const totalReceived = otherReceived
        return {
            underlyingIn: underlyingSpent,
            underlyingOut: ZERO,
            otherIn: ZERO,
            otherOut: otherReceived,
            totalGiven,
            totalReceived,
            netCost: totalGiven.gte(totalReceived)
                ? totalGiven.sub(totalReceived)
                : totalReceived.sub(totalGiven),
            netDirection: totalGiven.gte(totalReceived) ? "cost" : "gain",
            inferred: true,
        }
    }

    if (
        otherSpent.gt(0) &&
        underlyingReceived.gt(0) &&
        underlyingSpent.isZero() &&
        otherReceived.isZero()
    ) {
        const totalGiven = otherSpent
        const totalReceived = underlyingReceived
        return {
            underlyingIn: ZERO,
            underlyingOut: underlyingReceived,
            otherIn: otherSpent,
            otherOut: ZERO,
            totalGiven,
            totalReceived,
            netCost: totalGiven.gte(totalReceived)
                ? totalGiven.sub(totalReceived)
                : totalReceived.sub(totalGiven),
            netDirection: totalGiven.gte(totalReceived) ? "cost" : "gain",
            inferred: true,
        }
    }

    throw new Error("Tenderly simulation did not expose an unambiguous swap accounting path")
}

function swapTotalsEqual(left, right) {
    return (
        left.underlyingIn.eq(right.underlyingIn) &&
        left.underlyingOut.eq(right.underlyingOut) &&
        left.otherIn.eq(right.otherIn) &&
        left.otherOut.eq(right.otherOut)
    )
}

function assertTickConsistency({ decodedPlan, newPosition, events }) {
    if (newPosition.tickLower !== null && newPosition.tickLower !== decodedPlan.newTickLower) {
        throw new Error("Tenderly simulation minted a position with an unexpected new tick lower")
    }
    if (newPosition.tickUpper !== null && newPosition.tickUpper !== decodedPlan.newTickUpper) {
        throw new Error("Tenderly simulation minted a position with an unexpected new tick upper")
    }

    const rebalanceEvent = [...events]
        .reverse()
        .find((event) => event.name === "OnPositionRebalanced")
    if (rebalanceEvent) {
        const eventTickLower = toInt(rebalanceEvent.args.newTickLower, "rebalanced tickLower")
        const eventTickUpper = toInt(rebalanceEvent.args.newTickUpper, "rebalanced tickUpper")
        if (eventTickLower !== decodedPlan.newTickLower || eventTickUpper !== decodedPlan.newTickUpper) {
            throw new Error("Tenderly simulation reported unexpected rebalance tick bounds")
        }
    }
}

function bnSubChecked(label, a, b) {
    if (a.lt(b)) {
        throw new Error(`Notification accounting underflow while computing ${label}`)
    }
    return a.sub(b)
}

async function resolveDeadlineUnix({ decodedPlan, simulation, provider }) {
    if (decodedPlan.encoding === "legacy") {
        return decodedPlan.pmDeadlineRaw.toNumber()
    }

    let simulationTimestamp = extractSimulationTimestamp(simulation)
    if (!simulationTimestamp) {
        const simulationBlock = extractSimulationBlockNumber(simulation) || "latest"
        const block = await provider.getBlock(simulationBlock)
        simulationTimestamp = Number(block?.timestamp || 0)
    }

    if (!simulationTimestamp) {
        throw new Error("Tenderly simulation did not expose a usable timestamp for deadline formatting")
    }

    if (!decodedPlan.actionDataProvided) {
        return simulationTimestamp
    }
    if (decodedPlan.pmDeadlineRaw.gt(0)) {
        return decodedPlan.pmDeadlineRaw.toNumber()
    }
    return simulationTimestamp + DEFAULT_PM_DEADLINE_SECONDS
}

function formatUnixInRiyadh(unixSeconds) {
    const formatter = new Intl.DateTimeFormat("en-GB", {
        timeZone: "Asia/Riyadh",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: false,
    })

    const parts = formatter.formatToParts(new Date(unixSeconds * 1000))
    const lookup = Object.fromEntries(parts.map((part) => [part.type, part.value]))
    return `${lookup.year}-${lookup.month}-${lookup.day} ${lookup.hour}:${lookup.minute}:${lookup.second}`
}

function buildUniswapPositionUrl(chainName, tokenId) {
    const slug = UNISWAP_APP_CHAIN_SLUG[chainName]
    if (!slug || !tokenId) return null
    return `https://app.uniswap.org/positions/v3/${slug}/${tokenId}`
}

function formatTokenAmount(rawAmount, decimals, places = 6) {
    const normalized = utils.formatUnits(rawAmount || ZERO, decimals)
    const [whole, fraction = ""] = normalized.split(".")
    return `${whole}.${fraction.padEnd(places, "0").slice(0, places)}`
}

function formatSwapSummary(swapTotals, preState) {
    const pieces = []
    if (swapTotals.underlyingIn.gt(0)) {
        pieces.push(
            `Gave ${formatTokenAmount(swapTotals.underlyingIn, preState.underlyingDecimals)} ${preState.underlyingSymbol}`,
        )
    }
    if (swapTotals.otherIn.gt(0)) {
        pieces.push(`Gave ${formatTokenAmount(swapTotals.otherIn, preState.otherDecimals)} ${preState.otherSymbol}`)
    }
    if (swapTotals.underlyingOut.gt(0)) {
        pieces.push(
            `Received ${formatTokenAmount(swapTotals.underlyingOut, preState.underlyingDecimals)} ${preState.underlyingSymbol}`,
        )
    }
    if (swapTotals.otherOut.gt(0)) {
        pieces.push(
            `Received ${formatTokenAmount(swapTotals.otherOut, preState.otherDecimals)} ${preState.otherSymbol}`,
        )
    }

    const direction = swapTotals.netDirection === "cost" ? "-" : "+"
    const delta = formatTokenAmount(swapTotals.netCost, preState.underlyingDecimals)
    if (pieces.length === 0) {
        return "0.000000 stable units | No swap executed"
    }
    return `${delta} stable units | ${pieces.join(" | ")} | Net delta ${direction}${delta}`
}

function buildSafeFieldValue(safeResult) {
    if (!safeResult) return null
    const lines = []
    if (safeResult.queueUrl) {
        lines.push(`[Open Safe queue](${safeResult.queueUrl})`)
    }
    if (safeResult.txServiceTransactionUrl) {
        lines.push(`[Tx service record](${safeResult.txServiceTransactionUrl})`)
    }
    lines.push(`safeTxHash: \`${safeResult.safeTxHash}\``)
    return lines.join("\n")
}

function buildUniswapFieldValue(summary) {
    if (!summary.uniswapPositionUrl || !summary.newTokenId) {
        return "No new UniV3 token was minted in this simulation."
    }
    return [
        `[Open Uniswap position](${summary.uniswapPositionUrl})`,
        `Simulated token ID: \`${summary.newTokenId}\``,
        "Available after signing. The token ID can change if signing is delayed and the transaction is rebuilt later.",
    ].join("\n")
}

function buildSafeStatusLine(summary) {
    if (summary.safeResult) {
        return "Safe status: sent to Safe for signatures."
    }
    return "Safe status: not sent to Safe. Simulation only."
}

async function buildRebalanceNotificationSummary({
    chainCfg,
    preState,
    decodedPlan,
    simulation,
    safeResult,
}) {
    const assetChanges = normalizeAssetChanges(simulation)
    const events = parseStrategyEvents(simulation, preState.strategyAddress)
    const collectedPosition = deriveCollectedPosition(events, assetChanges, preState)
    const currentPosition = deriveDisplayedCurrentPosition(preState, collectedPosition)
    const newPosition = deriveNewPosition(events, assetChanges, preState)
    const { sweptUnderlying: remainingUnderlying, remainingOther } = deriveRemainingsFromAssetChanges(
        assetChanges,
        preState,
    )
    const swapTotalsFromEvents = deriveSwapTotalsFromEvents(events, preState)
    const swapTotalsFromAccounting = deriveSwapTotalsFromAccounting({
        preState,
        collectedPosition,
        newPosition,
        sweptUnderlying: remainingUnderlying,
        remainingOther,
    })
    const swapTotals = hasNonZeroTokenAmounts({
        underlying: swapTotalsFromEvents.underlyingIn.add(swapTotalsFromEvents.underlyingOut),
        other: swapTotalsFromEvents.otherIn.add(swapTotalsFromEvents.otherOut),
    })
        ? swapTotalsFromEvents
        : swapTotalsFromAccounting

    if (
        hasNonZeroTokenAmounts({
            underlying: swapTotalsFromEvents.underlyingIn.add(swapTotalsFromEvents.underlyingOut),
            other: swapTotalsFromEvents.otherIn.add(swapTotalsFromEvents.otherOut),
        }) &&
        !swapTotalsEqual(swapTotalsFromEvents, swapTotalsFromAccounting)
    ) {
        throw new Error("Tenderly swap events did not match the token accounting for the rebalance")
    }

    assertTickConsistency({ decodedPlan, newPosition, events })

    const deadlineUnix = await resolveDeadlineUnix({
        decodedPlan,
        simulation,
        provider: preState.provider,
    })

    const newTokenId = newPosition.tokenId ? newPosition.tokenId.toString() : null

    return {
        chainName: chainCfg.name,
        strategyAddress: preState.strategyAddress,
        currentPosition,
        swapTotals,
        newTickLower: decodedPlan.newTickLower,
        newTickUpper: decodedPlan.newTickUpper,
        newPosition,
        remainingUnderlying,
        remainingOther,
        deadlineUnix,
        deadlineRiyadh: formatUnixInRiyadh(deadlineUnix),
        safeFieldValue: buildSafeFieldValue(safeResult),
        safeResult,
        newTokenId,
        uniswapPositionUrl: buildUniswapPositionUrl(preState.chainName, newTokenId),
        tenderlyPublicUrl: simulation.publicUrl || null,
        tenderlyDashboardUrl: simulation.dashboardUrl || null,
    }
}

function renderDiscordPayload(summary, preState) {
    const fields = [
        {
            name: "Current position",
            value: `${formatTokenAmount(summary.currentPosition.underlying, preState.underlyingDecimals)} ${preState.underlyingSymbol} | ${formatTokenAmount(summary.currentPosition.other, preState.otherDecimals)} ${preState.otherSymbol}`,
            inline: false,
        },
        {
            name: "Swap cost",
            value: formatSwapSummary(summary.swapTotals, preState),
            inline: false,
        },
        { name: "New tick lower", value: String(summary.newTickLower), inline: true },
        { name: "New tick upper", value: String(summary.newTickUpper), inline: true },
        {
            name: "New position",
            value: `${formatTokenAmount(summary.newPosition.underlying, preState.underlyingDecimals)} ${preState.underlyingSymbol} | ${formatTokenAmount(summary.newPosition.other, preState.otherDecimals)} ${preState.otherSymbol}`,
            inline: false,
        },
        {
            name: "Remainings",
            value: `${formatTokenAmount(summary.remainingUnderlying, preState.underlyingDecimals)} ${preState.underlyingSymbol} swept to vault | ${formatTokenAmount(summary.remainingOther, preState.otherDecimals)} ${preState.otherSymbol} remaining in strategy`,
            inline: false,
        },
        {
            name: "Deadline",
            value: `${summary.deadlineRiyadh} Riyadh time (UTC+03:00)`,
            inline: false,
        },
    ]

    if (summary.safeFieldValue) {
        fields.push({ name: "Safe transaction", value: summary.safeFieldValue, inline: false })
    }
    fields.push({
        name: "Uniswap position",
        value: buildUniswapFieldValue(summary),
        inline: false,
    })

    return {
        username: process.env.DISCORD_WEBHOOK_USERNAME || undefined,
        allowed_mentions: { parse: [] },
        embeds: [
            {
                title: "Takasure UniV3 rebalance summary",
                description: buildSafeStatusLine(summary),
                color: 0x1f8b4c,
                fields,
            },
        ],
    }
}

function renderSummaryText(summary, preState) {
    const lines = [
        "Takasure UniV3 rebalance summary",
        buildSafeStatusLine(summary),
        `Current position: ${formatTokenAmount(summary.currentPosition.underlying, preState.underlyingDecimals)} ${preState.underlyingSymbol} | ${formatTokenAmount(summary.currentPosition.other, preState.otherDecimals)} ${preState.otherSymbol}`,
        `Swap cost: ${formatSwapSummary(summary.swapTotals, preState)}`,
        `New tick lower: ${summary.newTickLower}`,
        `New tick upper: ${summary.newTickUpper}`,
        `New position: ${formatTokenAmount(summary.newPosition.underlying, preState.underlyingDecimals)} ${preState.underlyingSymbol} | ${formatTokenAmount(summary.newPosition.other, preState.otherDecimals)} ${preState.otherSymbol}`,
        `Remainings: ${formatTokenAmount(summary.remainingUnderlying, preState.underlyingDecimals)} ${preState.underlyingSymbol} swept to vault | ${formatTokenAmount(summary.remainingOther, preState.otherDecimals)} ${preState.otherSymbol} remaining in strategy`,
        `Deadline (Riyadh time UTC+03:00): ${summary.deadlineRiyadh}`,
    ]

    if (summary.safeFieldValue) {
        lines.push("Safe transaction:")
        lines.push(summary.safeFieldValue)
    }

    lines.push("Uniswap position:")
    lines.push(buildUniswapFieldValue(summary))

    if (summary.tenderlyPublicUrl) {
        lines.push(`Tenderly public URL: ${summary.tenderlyPublicUrl}`)
    }
    if (summary.tenderlyDashboardUrl) {
        lines.push(`Tenderly dashboard URL: ${summary.tenderlyDashboardUrl}`)
    }

    return lines.join("\n")
}

module.exports = {
    buildRebalanceNotificationSummary,
    decodeSingleStrategyRebalancePlan,
    ensureNotificationSupported,
    formatUnixInRiyadh,
    parseDiscordNotificationFlags,
    readStrategyPreState,
    renderDiscordPayload,
    renderSummaryText,
}
