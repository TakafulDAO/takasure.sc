require("dotenv").config()
const { ethers } = require("ethers")

const DEFAULT_GAS = "8000000"
const DEFAULT_BLOCK = "latest"

async function postJson(url, body, accessKey) {
    const fetch =
        typeof window === "undefined" ? (await import("node-fetch")).default : window.fetch
    const response = await fetch(url, {
        method: "POST",
        headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            "X-Access-Key": accessKey,
        },
        body: JSON.stringify(body),
    })

    const text = await response.text()
    if (!response.ok) {
        throw new Error(text || response.statusText)
    }
    try {
        return JSON.parse(text)
    } catch {
        return text
    }
}

function extractSimulationStatus(result) {
    const candidates = [
        result?.simulation?.status,
        result?.transaction?.status,
        result?.simulation?.transaction?.status,
        result?.transaction?.transaction_info?.status,
    ]
    for (const v of candidates) {
        if (typeof v === "boolean") return v
    }
    return null
}

function extractSimulationId(result) {
    return result?.simulation?.id || result?.simulation_id || null
}

function extractShareUrl(result) {
    return (
        result?.share_url ||
        result?.shareUrl ||
        result?.public_url ||
        result?.publicUrl ||
        result?.public_uri ||
        result?.url ||
        null
    )
}

async function shareSimulation({ account, project, simulationId, accessKey }) {
    const shareUrl = `https://api.tenderly.co/api/v1/account/${account}/project/${project}/simulations/${simulationId}/share`
    const shareResp = await postJson(shareUrl, {}, accessKey)
    return { shareResp, publicUrl: extractShareUrl(shareResp) }
}

function buildDashboardUrl(simulationId) {
    if (!simulationId) return null
    return `https://dashboard.tenderly.co/simulator/${simulationId}`
}

async function simulateTenderly({
    chainCfg,
    from,
    to,
    data,
    value,
    gas,
    blockNumber,
    simulationType,
}) {
    if (!chainCfg || !chainCfg.chainId) {
        console.error("Missing chain config (chainId) for Tenderly simulation")
        process.exit(1)
    }

    const accessKey = process.env.TENDERLY_ACCESS_KEY

    if (!accessKey) {
        console.error("Missing Tenderly env vars: TENDERLY_ACCESS_KEY")
        process.exit(1)
    }

    const account = process.env.TENDERLY_ACCOUNT_SLUG

    if (!account) {
        console.error("Missing Tenderly env vars: TENDERLY_ACCOUNT_SLUG")
        process.exit(1)
    }

    const project = process.env.TENDERLY_PROJECT_SLUG

    if (!project) {
        console.error("Missing Tenderly env vars: TENDERLY_PROJECT_SLUG")
        process.exit(1)
    }

    const url = `https://api.tenderly.co/api/v1/account/${account}/project/${project}/simulate`
    const payload = {
        network_id: String(chainCfg.chainId),
        from: ethers.utils.getAddress(from),
        to: ethers.utils.getAddress(to),
        input: data,
        gas: parseInt(gas || DEFAULT_GAS, 10),
        value: value || "0",
        save: true,
        save_if_fails: true,
    }

    if (blockNumber) {
        const normalized = String(blockNumber).toLowerCase()
        if (normalized === "latest" || normalized === "pending") {
            // Tenderly REST expects a numeric block_number; omit to use latest
        } else {
            const parsed = parseInt(blockNumber, 10)
            if (!Number.isFinite(parsed)) {
                console.error(`Invalid tenderly block number: ${blockNumber}`)
                process.exit(1)
            }
            payload.block_number = parsed
        }
    }

    if (simulationType) {
        payload.simulation_type = simulationType
    }

    const result = await postJson(url, payload, accessKey)
    const status = extractSimulationStatus(result)
    const simulationId = extractSimulationId(result)
    const dashboardUrl = buildDashboardUrl(simulationId)
    let publicUrl = null

    if (simulationId) {
        try {
            const share = await shareSimulation({
                account,
                project,
                simulationId,
                accessKey,
            })
            publicUrl = share.publicUrl
        } catch (err) {}
    }

    return { result, status, simulationId, publicUrl, dashboardUrl, url }
}

module.exports = {
    simulateTenderly,
}
