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
function argHas(flag) {
    return process.argv.includes(flag)
}

async function refundAllEthBack(userWallet, rolesEOA, provider, opts = {}) {
    const debug = !!opts.debug
    const safety = opts.safetyWei || ethers.utils.parseEther("0.00005") // buffer

    const feeData = await provider.getFeeData()
    const maxFeePerGas =
        feeData.maxFeePerGas || feeData.gasPrice || ethers.utils.parseUnits("0.2", "gwei")
    const maxPriorityFeePerGas =
        feeData.maxPriorityFeePerGas || ethers.utils.parseUnits("0.01", "gwei")

    const bal = await provider.getBalance(userWallet.address)
    if (bal.isZero()) return { sent: false, reason: "zero balance", bal }

    // 1) Estimate gas for a value=0 transfer (gas usage doesn't depend on value)
    let estGas = ethers.BigNumber.from(21000)
    try {
        estGas = await provider.estimateGas({
            from: userWallet.address,
            to: rolesEOA,
            value: ethers.constants.Zero,
        })
    } catch (e) {
        // if estimate fails, fall back to a safe higher gas
        estGas = ethers.BigNumber.from(100000)
    }

    // 2) Add buffer
    const gasLimit = estGas.mul(120).div(100).add(5000) // +20% and +5k

    // 3) Reserve enough to pay for that gas + safety
    const feeReserve = gasLimit.mul(maxFeePerGas).add(safety)
    if (bal.lte(feeReserve)) {
        return { sent: false, reason: "not enough after gas reserve", bal, feeReserve, gasLimit }
    }

    const value = bal.sub(feeReserve)

    const txReq = { to: rolesEOA, value, gasLimit }

    if (feeData.maxFeePerGas) {
        txReq.maxFeePerGas = maxFeePerGas
        txReq.maxPriorityFeePerGas = maxPriorityFeePerGas
    } else if (feeData.gasPrice) {
        txReq.gasPrice = feeData.gasPrice
    }

    if (debug) {
        console.log(
            `[debug] ${userWallet.address} bal=${ethers.utils.formatEther(bal)} gasLimit=${gasLimit.toString()} reserve=${ethers.utils.formatEther(
                feeReserve,
            )} send=${ethers.utils.formatEther(value)}`,
        )
    }

    const tx = await userWallet.sendTransaction(txReq)
    const receipt = await tx.wait(1)
    return { sent: true, value, hash: receipt.transactionHash, gasLimit }
}

async function main() {
    const RPC_URL = process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    if (!RPC_URL) throw new Error("Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL in .env")

    const jsonPath = argValue("--json", "")
    if (!jsonPath) throw new Error('Usage: node sweep_refunds.js --json "<path-to-users.json>"')

    const DEBUG = argHas("--debug")
    const LIMIT = Number(argValue("--limit", "0")) // 0 = no limit

    const users = JSON.parse(fs.readFileSync(jsonPath, "utf8"))
    const provider = new ethers.providers.JsonRpcProvider(RPC_URL)

    let ok = 0,
        fail = 0

    for (let i = 0; i < users.length; i++) {
        if (LIMIT > 0 && i >= LIMIT) break
        const u = users[i]

        try {
            const w = new ethers.Wallet(u.privateKey, provider)
            const res = await refundAllEthBack(w, ROLES_EOA, provider, { debug: DEBUG })

            if (res.sent) {
                ok++
                if (ok % 10 === 0) console.log(`refunded ${ok}/${users.length}`)
            } else {
                fail++
                if (DEBUG) {
                    console.log(
                        `[skip] idx=${u.idx ?? i} addr=${w.address} reason=${res.reason} bal=${ethers.utils.formatEther(
                            res.bal,
                        )} reserve=${res.feeReserve ? ethers.utils.formatEther(res.feeReserve) : "?"} gasLimit=${
                            res.gasLimit ? res.gasLimit.toString() : "?"
                        }`,
                    )
                }
            }
        } catch (e) {
            fail++
            const msg = e?.error?.message || e?.reason || e?.message || String(e)
            if (DEBUG) console.log(`[fail] idx=${u.idx ?? i} addr=${u.address} err=${msg}`)
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
