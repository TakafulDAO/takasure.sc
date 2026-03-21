require("dotenv").config()
const { ethers } = require("ethers")

async function sendOnchain({ to, data, value, chainCfg }) {
    if (!chainCfg || chainCfg.name !== "arb-sepolia") {
        console.error("--sendTx is only supported for --chain arb-sepolia")
        process.exit(1)
    }

    const rpcUrl = process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    const pkRaw = process.env.TESTNET_PK

    if (!rpcUrl) {
        console.error("Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL")
        process.exit(1)
    }
    if (!pkRaw) {
        console.error("Missing TESTNET_PK")
        process.exit(1)
    }

    const pk = pkRaw.startsWith("0x") ? pkRaw : `0x${pkRaw}`
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl)
    const wallet = new ethers.Wallet(pk, provider)

    const txRequest = {
        to: ethers.utils.getAddress(to),
        data,
        value: value || "0",
    }

    try {
        await wallet.call(txRequest)
    } catch (error) {
        const reason =
            error?.error?.message ||
            error?.reason ||
            error?.message ||
            "unknown preflight failure"
        throw new Error(`Preflight call failed for onchain batch tx: ${reason}`)
    }

    let gasLimit
    try {
        const estimatedGas = await wallet.estimateGas(txRequest)
        gasLimit = estimatedGas.mul(130).div(100)
    } catch (error) {
        const reason =
            error?.error?.message ||
            error?.reason ||
            error?.message ||
            "unknown gas estimation failure"
        throw new Error(`Gas estimation failed for onchain batch tx: ${reason}`)
    }

    const tx = await wallet.sendTransaction({
        ...txRequest,
        gasLimit,
    })

    const receipt = await tx.wait()
    if (receipt.status !== 1) {
        throw new Error(
            `Onchain batch tx reverted after broadcast: hash=${tx.hash} gasUsed=${receipt.gasUsed.toString()} gasLimit=${gasLimit.toString()}`,
        )
    }

    return {
        hash: tx.hash,
        from: tx.from,
        to: tx.to,
        nonce: tx.nonce,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
        gasLimit: gasLimit.toString(),
    }
}

module.exports = {
    sendOnchain,
}
