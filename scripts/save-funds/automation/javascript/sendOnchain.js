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

    const tx = await wallet.sendTransaction({
        to: ethers.utils.getAddress(to),
        data,
        value: value || "0",
    })

    const receipt = await tx.wait()
    return {
        hash: tx.hash,
        from: tx.from,
        to: tx.to,
        nonce: tx.nonce,
        blockNumber: receipt.blockNumber,
        gasUsed: receipt.gasUsed.toString(),
    }
}

module.exports = {
    sendOnchain,
}
