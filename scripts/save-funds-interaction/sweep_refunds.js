require("dotenv").config()

const fs = require("fs")
const { ethers } = require("ethers")

const ROLES_EOA = "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1"

function argValue(flag, def) {
    const i = process.argv.indexOf(flag)
    if (i === -1) return def
    const v = process.argv[i + 1]
    if (!v || v.startsWith("--")) return def
    return v
}

async function refundAllEthBack(userWallet, rolesEOA, provider) {
    const feeData = await provider.getFeeData()

    const maxFeePerGas =
        feeData.maxFeePerGas || feeData.gasPrice || ethers.utils.parseUnits("0.1", "gwei")
    const maxPriorityFeePerGas =
        feeData.maxPriorityFeePerGas || ethers.utils.parseUnits("0.01", "gwei")

    const bal = await provider.getBalance(userWallet.address)
    if (bal.isZero()) return { sent: false, reason: "zero balance" }

    const gasLimit = ethers.BigNumber.from(21000)
    const safety = ethers.utils.parseEther("0.00002")

    const feeReserve = gasLimit.mul(maxFeePerGas).add(safety)
    if (bal.lte(feeReserve)) return { sent: false, reason: "not enough after gas reserve" }

    const value = bal.sub(feeReserve)

    const txReq = { to: rolesEOA, value, gasLimit }
    if (feeData.maxFeePerGas) {
        txReq.maxFeePerGas = maxFeePerGas
        txReq.maxPriorityFeePerGas = maxPriorityFeePerGas
    } else if (feeData.gasPrice) {
        txReq.gasPrice = feeData.gasPrice
    }

    const tx = await userWallet.sendTransaction(txReq)
    const receipt = await tx.wait(1)
    return { sent: true, value, hash: receipt.transactionHash }
}

async function main() {
    const RPC_URL = process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    if (!RPC_URL) throw new Error("Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL in .env")

    const jsonPath = argValue("--json", "")
    if (!jsonPath) throw new Error("Usage: node sweep_refunds.js --json <path-to-users.json>")

    const users = JSON.parse(fs.readFileSync(jsonPath, "utf8"))

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL)

    let ok = 0,
        fail = 0
    for (const u of users) {
        try {
            const w = new ethers.Wallet(u.privateKey, provider)
            const res = await refundAllEthBack(w, ROLES_EOA, provider)
            if (res.sent) {
                ok++
                if (ok % 10 === 0) console.log(`refunded ${ok}/${users.length}`)
            } else {
                fail++
            }
        } catch (e) {
            fail++
        }
    }

    console.log("Refund sweep done.")
    console.log("  refunded:", ok)
    console.log("  not refunded:", fail)
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})
