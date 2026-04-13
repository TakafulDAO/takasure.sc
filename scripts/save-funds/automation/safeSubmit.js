require("dotenv").config()
const { ethers } = require("ethers")
const Safe = require("@safe-global/protocol-kit").default

const SAFE_ADDRESS = "0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F"
const DEFAULT_TX_SERVICE_URL = "https://safe-transaction-arbitrum.safe.global/api/v1"
const SAFE_APP_NETWORK_PREFIX = "arb1"

async function postJson(url, body) {
    const fetch =
        typeof window === "undefined"
            ? (await import("node-fetch")).default
            : window.fetch
    const response = await fetch(url, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/json" },
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

async function sendToSafe({ to, data, value }) {
    const rpcUrl = process.env.SAFE_RPC_URL || process.env.ARBITRUM_MAINNET_RPC_URL
    const signerPk = process.env.SAFE_PROPOSER_PK
    if (!rpcUrl) {
        console.error("Missing SAFE_RPC_URL or ARBITRUM_MAINNET_RPC_URL")
        process.exit(1)
    }
    if (!signerPk) {
        console.error("Missing SAFE_PROPOSER_PK")
        process.exit(1)
    }

    const safeAddress = ethers.utils.getAddress(SAFE_ADDRESS)
    const toChecksum = ethers.utils.getAddress(to)

    const safeSdk = await Safe.init({
        provider: rpcUrl,
        signer: signerPk,
        safeAddress,
    })

    const safeTx = await safeSdk.createTransaction({
        transactions: [
            {
                to: toChecksum,
                data,
                value: value || "0",
            },
        ],
    })

    const safeTxHash = await safeSdk.getTransactionHash(safeTx)
    const senderSignature = await safeSdk.signHash(safeTxHash)

    const txServiceUrl = process.env.SAFE_TX_SERVICE_URL || DEFAULT_TX_SERVICE_URL
    const senderAddress = ethers.utils.getAddress(
        senderSignature.signer || new ethers.Wallet(signerPk).address,
    )

    const proposeUrl = `${txServiceUrl}/safes/${safeAddress}/multisig-transactions/`
    const payload = {
        ...safeTx.data,
        // Ensure API receives checksummed addresses even if SDK normalizes case
        to: toChecksum,
        contractTransactionHash: safeTxHash,
        sender: senderAddress,
        signature: senderSignature.data,
    }

    await postJson(proposeUrl, payload)

    return {
        safeTxHash,
        txServiceUrl,
        queueUrl: buildSafeQueueUrl({ safeAddress }),
        txServiceTransactionUrl: buildSafeServiceTransactionUrl({
            txServiceUrl,
            safeTxHash,
        }),
    }
}

function buildSafeQueueUrl({ safeAddress = SAFE_ADDRESS, chainPrefix = SAFE_APP_NETWORK_PREFIX } = {}) {
    return `https://app.safe.global/transactions/queue?safe=${chainPrefix}:${ethers.utils.getAddress(safeAddress)}`
}

function buildSafeServiceTransactionUrl({ txServiceUrl = DEFAULT_TX_SERVICE_URL, safeTxHash }) {
    if (!safeTxHash) return null
    const base = String(txServiceUrl).replace(/\/+$/, "")
    return `${base}/multisig-transactions/${safeTxHash}/`
}

module.exports = {
    buildSafeQueueUrl,
    buildSafeServiceTransactionUrl,
    SAFE_ADDRESS,
    SAFE_APP_NETWORK_PREFIX,
    sendToSafe,
}
