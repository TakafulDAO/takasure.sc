const assert = require("node:assert/strict")
const test = require("node:test")
const { getChainConfig } = require("../chainConfig")
const { deliverDiscordNotification, postDiscordWebhook } = require("../discordWebhook")
const {
    buildRebalanceNotificationSummary,
    decodeSingleStrategyRebalancePlan,
    ensureNotificationSupported,
    parseDiscordNotificationFlags,
    renderDiscordPayload,
    renderSummaryText,
} = require("../rebalanceNotification")
const {
    ADDR,
    buildBundleData,
    buildRebalancePayload,
    happyPath,
    noPosition,
    noSwap,
    sweepOnly,
} = require("./fixtures/rebalanceNotificationFixtures")

test("builds a happy-path rebalance summary with Safe and Uniswap links", async () => {
    const summary = await buildRebalanceNotificationSummary({
        chainCfg: getChainConfig("arb-one"),
        preState: happyPath.preState,
        decodedPlan: happyPath.decodedPlan,
        simulation: happyPath.simulation,
        safeResult: happyPath.safeResult,
    })

    assert.equal(summary.newTickLower, -594)
    assert.equal(summary.newTickUpper, 606)
    assert.equal(summary.deadlineRiyadh, "2024-05-06 15:58:20")
    assert.equal(summary.newTokenId, "5417305")
    assert.equal(summary.uniswapPositionUrl, "https://app.uniswap.org/positions/v3/arbitrum/5417305")
    assert.equal(summary.currentPosition.underlying.toString(), "13334850")
    assert.equal(summary.currentPosition.other.toString(), "2414890")
    assert.equal(summary.remainingUnderlying.toString(), "0")
    assert.equal(summary.remainingOther.toString(), "76878")
    assert.match(summary.safeFieldValue, /Open Safe queue/)

    const payload = renderDiscordPayload(summary, happyPath.preState)
    const safeField = payload.embeds[0].fields.find((field) => field.name === "Safe transaction")
    const uniswapField = payload.embeds[0].fields.find((field) => field.name === "Uniswap position")
    assert.ok(safeField)
    assert.ok(uniswapField.value.includes("5417305"))
    assert.equal(payload.embeds[0].description, "Safe status: sent to Safe for signatures.")
})

test("falls back to token accounting when the explicit swap event is missing", async () => {
    const simulationWithoutSwapEvent = {
        ...happyPath.simulation,
        transaction: {
            ...happyPath.simulation.transaction,
            logs: happyPath.simulation.transaction.logs.filter((log, index) => index !== 1),
        },
        logs: happyPath.simulation.logs.filter((log, index) => index !== 1),
    }

    const summary = await buildRebalanceNotificationSummary({
        chainCfg: getChainConfig("arb-one"),
        preState: happyPath.preState,
        decodedPlan: happyPath.decodedPlan,
        simulation: simulationWithoutSwapEvent,
        safeResult: null,
    })

    assert.equal(summary.swapTotals.underlyingIn.toString(), "7622603")
    assert.equal(summary.swapTotals.otherOut.toString(), "7618317")
})

test("reports zero swap cost and zero remainings when rebalance remints directly", async () => {
    const summary = await buildRebalanceNotificationSummary({
        chainCfg: getChainConfig("arb-one"),
        preState: noSwap.preState,
        decodedPlan: noSwap.decodedPlan,
        simulation: noSwap.simulation,
        safeResult: null,
    })

    assert.equal(summary.swapTotals.netCost.toString(), "0")
    assert.equal(summary.remainingUnderlying.toString(), "0")
    assert.equal(summary.remainingOther.toString(), "0")
    assert.equal(summary.deadlineUnix, 1715000900)

    const payload = renderDiscordPayload(summary, noSwap.preState)
    assert.equal(payload.embeds[0].description, "Safe status: not sent to Safe. Simulation only.")
})

test("handles a no-position rebalance and resolves the default PM deadline from simulation time", async () => {
    const summary = await buildRebalanceNotificationSummary({
        chainCfg: getChainConfig("arb-one"),
        preState: noPosition.preState,
        decodedPlan: noPosition.decodedPlan,
        simulation: noPosition.simulation,
        safeResult: null,
    })

    assert.equal(summary.currentPosition.underlying.toString(), "0")
    assert.equal(summary.currentPosition.other.toString(), "0")
    assert.equal(summary.newPosition.underlying.toString(), "0")
    assert.equal(summary.newPosition.other.toString(), "0")
    assert.equal(summary.newTokenId, null)
    assert.equal(summary.deadlineUnix, 1715000300)
})

test("computes a pure USDC sweep to vault correctly", async () => {
    const summary = await buildRebalanceNotificationSummary({
        chainCfg: getChainConfig("arb-one"),
        preState: sweepOnly.preState,
        decodedPlan: sweepOnly.decodedPlan,
        simulation: sweepOnly.simulation,
        safeResult: null,
    })

    assert.equal(summary.remainingUnderlying.toString(), "1000000")
    assert.equal(summary.remainingOther.toString(), "0")
})

test("rejects notification summary generation when Tenderly asset changes are missing", async () => {
    await assert.rejects(
        buildRebalanceNotificationSummary({
            chainCfg: getChainConfig("arb-one"),
            preState: happyPath.preState,
            decodedPlan: happyPath.decodedPlan,
            simulation: { transaction: { logs: happyPath.simulation.logs } },
            safeResult: null,
        }),
        /asset_changes/,
    )
})

test("validates flag parsing and request guardrails", () => {
    const flags = parseDiscordNotificationFlags(["node", "script", "--discorNotification"])
    assert.equal(flags.wantsDiscordNotification, true)
    assert.equal(flags.usedDeprecatedAlias, true)

    const oldWebhook = process.env.DISCORD_WEBHOOK_URL
    delete process.env.DISCORD_WEBHOOK_URL
    assert.throws(
        () =>
            ensureNotificationSupported({
                wantsDiscordNotification: true,
                chainCfg: getChainConfig("arb-one"),
                wantsSendTx: false,
            }),
        /DISCORD_WEBHOOK_URL/,
    )
    process.env.DISCORD_WEBHOOK_URL = "https://discord.test/webhook"
    assert.throws(
        () =>
            ensureNotificationSupported({
                wantsDiscordNotification: true,
                chainCfg: getChainConfig("arb-sepolia"),
                wantsSendTx: false,
            }),
        /arb-one/,
    )
    if (oldWebhook === undefined) {
        delete process.env.DISCORD_WEBHOOK_URL
    } else {
        process.env.DISCORD_WEBHOOK_URL = oldWebhook
    }
})

test("rejects unsupported rebalance bundle shapes for notification mode", () => {
    const chainCfg = getChainConfig("arb-one")

    const supportedPayload = buildRebalancePayload({
        tickLower: -594,
        tickUpper: 606,
        encoding: "new",
        actionDataProvided: true,
        pmDeadlineRaw: "0",
    })
    const supportedData = buildBundleData({
        strategies: [ADDR.strategy],
        payloads: [supportedPayload],
    })
    const supportedPlan = decodeSingleStrategyRebalancePlan({ chainCfg, data: supportedData })
    assert.equal(supportedPlan.strategyAddress.toLowerCase(), ADDR.strategy.toLowerCase())

    const multiData = buildBundleData({
        strategies: [ADDR.strategy, "0x1111111111111111111111111111111111111111"],
        payloads: [supportedPayload, supportedPayload],
    })
    assert.throws(
        () => decodeSingleStrategyRebalancePlan({ chainCfg, data: multiData }),
        /exactly one strategy/,
    )

    const otherData = buildBundleData({
        strategies: ["0x1111111111111111111111111111111111111111"],
        payloads: [supportedPayload],
    })
    assert.throws(
        () => decodeSingleStrategyRebalancePlan({ chainCfg, data: otherData }),
        /SFUniswapV3Strategy/,
    )
})

test("retries Discord delivery once on rate limit", async () => {
    let calls = 0
    const fetchImpl = async () => {
        calls += 1
        if (calls === 1) {
            return {
                ok: false,
                status: 429,
                headers: { get: () => "0.001" },
                async text() {
                    return JSON.stringify({ retry_after: 0.001 })
                },
            }
        }
        return {
            ok: true,
            status: 200,
            headers: { get: () => null },
            async text() {
                return JSON.stringify({ id: "message-1" })
            },
        }
    }

    const result = await postDiscordWebhook({
        webhookUrl: "https://discord.test/webhook",
        payload: { embeds: [{ title: "hello" }] },
        fetchImpl,
    })

    assert.equal(result.ok, true)
    assert.equal(calls, 2)
})

test("warns and prints the rendered summary when Discord delivery fails", async () => {
    const warnings = []
    const logs = []
    const result = await deliverDiscordNotification({
        webhookUrl: "https://discord.test/webhook",
        payload: { embeds: [{ title: "hello" }] },
        summaryText: "SUMMARY BODY",
        fetchImpl: async () => ({
            ok: false,
            status: 500,
            headers: { get: () => null },
            async text() {
                return JSON.stringify({ message: "boom" })
            },
        }),
        logFn: (line) => logs.push(line),
        warnFn: (line) => warnings.push(line),
    })

    assert.equal(result.ok, false)
    assert.equal(logs.includes("SUMMARY BODY"), true)
    assert.equal(warnings.some((line) => line.includes("discordNotificationStatus: failed")), true)
})

test("renders a plain-text fallback summary with the key signer-facing fields", async () => {
    const summary = await buildRebalanceNotificationSummary({
        chainCfg: getChainConfig("arb-one"),
        preState: happyPath.preState,
        decodedPlan: happyPath.decodedPlan,
        simulation: happyPath.simulation,
        safeResult: happyPath.safeResult,
    })

    const text = renderSummaryText(summary, happyPath.preState)
    assert.match(text, /Safe status: sent to Safe for signatures\./)
    assert.match(text, /Current position:/)
    assert.match(text, /Swap cost:/)
    assert.match(text, /Deadline \(Riyadh time UTC\+03:00\):/)
    assert.match(text, /Open Uniswap position/)
    assert.doesNotMatch(text, /Strategy:/)
})
