async function getFetch(fetchImpl) {
    if (fetchImpl) return fetchImpl
    if (typeof window !== "undefined" && typeof window.fetch === "function") {
        return window.fetch.bind(window)
    }
    return (await import("node-fetch")).default
}

function getRetryDelayMs(response, body) {
    const headerDelay = response?.headers?.get?.("Retry-After")
    if (headerDelay) {
        const parsed = Number(headerDelay)
        if (Number.isFinite(parsed) && parsed > 0) {
            return parsed <= 100 ? Math.ceil(parsed * 1000) : Math.ceil(parsed)
        }
    }

    const retryAfter = Number(body?.retry_after)
    if (Number.isFinite(retryAfter) && retryAfter > 0) {
        return retryAfter <= 100 ? Math.ceil(retryAfter * 1000) : Math.ceil(retryAfter)
    }

    return 1000
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms))
}

async function postDiscordWebhook({ webhookUrl, payload, fetchImpl }) {
    const fetch = await getFetch(fetchImpl)

    for (let attempt = 0; attempt < 2; ++attempt) {
        const response = await fetch(`${webhookUrl}?wait=true`, {
            method: "POST",
            headers: {
                Accept: "application/json",
                "Content-Type": "application/json",
            },
            body: JSON.stringify(payload),
        })

        const text = await response.text()
        let body = null
        try {
            body = text ? JSON.parse(text) : null
        } catch (err) {}

        if (response.ok) {
            return { ok: true, response: body, status: response.status }
        }

        if (response.status === 429 && attempt === 0) {
            await sleep(getRetryDelayMs(response, body))
            continue
        }

        const error = new Error(
            body?.message || text || `Discord webhook request failed with status ${response.status}`,
        )
        error.status = response.status
        error.body = body
        throw error
    }

    throw new Error("Discord webhook request exhausted retries")
}

async function deliverDiscordNotification({
    webhookUrl,
    payload,
    summaryText,
    fetchImpl,
    logFn = console.log,
    warnFn = console.warn,
}) {
    try {
        const result = await postDiscordWebhook({ webhookUrl, payload, fetchImpl })
        logFn("discordNotificationStatus: sent")
        return { ok: true, result }
    } catch (err) {
        warnFn(`discordNotificationStatus: failed (${err.message || err})`)
        warnFn("Discord delivery failed. Rendered summary follows for manual resend:")
        logFn(summaryText)
        return { ok: false, error: err }
    }
}

module.exports = {
    deliverDiscordNotification,
    postDiscordWebhook,
}
