require("dotenv").config()
const { ethers } = require("ethers")
const SafeApiKit = require("@safe-global/api-kit").default
const Safe = require("@safe-global/protocol-kit").default

const SAFE_ADDRESS = "0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F"
const DEFAULT_TX_SERVICE_URL = "https://safe-transaction-arbitrum.safe.global/api/v1"
const ARBITRUM_ONE_CHAIN_ID = 42161n

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
    return sendTransactionsToSafe({
        transactions: [
            {
                to,
                data,
                value: value || "0",
            },
        ],
    })
}

function resolveSafeBaseConfig() {
    return {
        txServiceUrl: process.env.SAFE_TX_SERVICE_URL || DEFAULT_TX_SERVICE_URL,
        txServiceApiKey: process.env.SAFE_TX_SERVICE_API_KEY,
        safeAddress: ethers.utils.getAddress(SAFE_ADDRESS),
    }
}

function resolveSafeSubmissionConfig({ rpcUrl } = {}) {
    const resolvedRpcUrl = rpcUrl || process.env.SAFE_RPC_URL || process.env.ARBITRUM_MAINNET_RPC_URL
    const signerPk = process.env.SAFE_PROPOSER_PK
    if (!resolvedRpcUrl) {
        console.error("Missing SAFE_RPC_URL or ARBITRUM_MAINNET_RPC_URL")
        process.exit(1)
    }
    if (!signerPk) {
        console.error("Missing SAFE_PROPOSER_PK")
        process.exit(1)
    }

    return {
        rpcUrl: resolvedRpcUrl,
        signerPk,
        ...resolveSafeBaseConfig(),
    }
}

async function getNextSafeNonce() {
    const { txServiceUrl, txServiceApiKey, safeAddress } = resolveSafeBaseConfig()
    const safeApiKit = new SafeApiKit({
        chainId: ARBITRUM_ONE_CHAIN_ID,
        txServiceUrl,
        apiKey: txServiceApiKey,
    })

    const nextNonce = await safeApiKit.getNextNonce(safeAddress)
    return Number(nextNonce)
}

async function sendTransactionsToSafe({ transactions, nonce, rpcUrl }) {
    const {
        rpcUrl: resolvedRpcUrl,
        signerPk,
        txServiceUrl,
        safeAddress,
    } = resolveSafeSubmissionConfig({ rpcUrl })
    if (!Array.isArray(transactions) || transactions.length === 0) {
        throw new Error("transactions must be a non-empty array")
    }

    const normalizedTransactions = transactions.map((tx) => ({
        to: ethers.utils.getAddress(tx.to),
        data: tx.data,
        value: tx.value || "0",
    }))

    const safeSdk = await Safe.init({
        provider: resolvedRpcUrl,
        signer: signerPk,
        safeAddress,
    })

    const txOptions = Number.isInteger(nonce) ? { nonce } : undefined
    const safeTx = await safeSdk.createTransaction({
        transactions: normalizedTransactions,
        options: txOptions,
    })

    const safeTxHash = await safeSdk.getTransactionHash(safeTx)
    const senderSignature = await safeSdk.signHash(safeTxHash)

    const senderAddress = ethers.utils.getAddress(
        senderSignature.signer || new ethers.Wallet(signerPk).address,
    )

    const proposeUrl = `${txServiceUrl}/safes/${safeAddress}/multisig-transactions/`
    const payload = {
        ...safeTx.data,
        contractTransactionHash: safeTxHash,
        sender: senderAddress,
        signature: senderSignature.data,
    }
    if (payload.to) {
        payload.to = ethers.utils.getAddress(payload.to)
    }

    await postJson(proposeUrl, payload)

    return {
        safeTxHash,
        txServiceUrl,
        senderAddress,
        safeAddress,
        nonce: Number(safeTx.data.nonce),
    }
}

module.exports = {
    SAFE_ADDRESS,
    getNextSafeNonce,
    sendToSafe,
    sendTransactionsToSafe,
}
