require("dotenv").config()
const { ethers } = require("ethers")
const fs = require("fs")
const path = require("path")
const revShareModuleDeployment = require("../../deployments/mainnet_arbitrum_one/RevShareModule.json")

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

// Allocations output file
const ALLOCATIONS_FILE = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.json",
)

// Output for the Safe Transaction Builder JSON
const OUT_SAFE_JSON = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/safe/revshare_backfill_safe_batch.json",
)

const REV_SHARE_MODULE_ADDRESS = revShareModuleDeployment.address
const REV_SHARE_MODULE_ABI = revShareModuleDeployment.abi

// Safe config
const SAFE_ADDRESS = process.env.SAFE_ADDRESS
const SAFE_CHAIN_ID = (process.env.SAFE_CHAIN_ID || "42161").toString() // Arbitrum One

// Batch size for adminBackfillRevenue
const BATCH_SIZE = parseInt(process.env.BACKFILL_BATCH_SIZE || "20", 10)

/*//////////////////////////////////////////////////////////////
                                MAIN
//////////////////////////////////////////////////////////////*/

async function main() {
    console.log("=== Build Safe Transaction Builder JSON for RevShare backfill ===")

    if (!SAFE_ADDRESS) {
        throw new Error("SAFE_ADDRESS is not set in .env")
    }

    if (!REV_SHARE_MODULE_ADDRESS || !REV_SHARE_MODULE_ABI) {
        throw new Error("RevShareModule deployment JSON must have address and abi")
    }

    if (!fs.existsSync(ALLOCATIONS_FILE)) {
        throw new Error(
            `Allocations file not found at ${ALLOCATIONS_FILE}. Run 02-buildRevShareBackfillAllocations first.`,
        )
    }

    const allocationsJson = JSON.parse(fs.readFileSync(ALLOCATIONS_FILE, "utf8"))
    const allocations = allocationsJson.allocations || []

    if (allocations.length === 0) {
        throw new Error("No allocations found in revshare_backfill_allocations.json")
    }

    console.log(
        `Loaded ${allocations.length} allocations from ${ALLOCATIONS_FILE} (batch size = ${BATCH_SIZE})`,
    )

    // Interface to encode adminBackfillRevenue(address[], uint256[])
    const iface = new ethers.utils.Interface(REV_SHARE_MODULE_ABI)

    const transactions = []

    // Split allocations into batches
    for (let i = 0; i < allocations.length; i += BATCH_SIZE) {
        const slice = allocations.slice(i, i + BATCH_SIZE)

        const accounts = slice.map((a) => String(a.address).toLowerCase())
        const amounts = slice.map((a) => a.amountRaw) // uint256 as string

        // Sanity check
        if (accounts.length === 0) continue
        if (accounts.length !== amounts.length) {
            throw new Error("accounts.length !== amounts.length in a batch, something is wrong")
        }

        const data = iface.encodeFunctionData("adminBackfillRevenue", [accounts, amounts])

        // Transaction object in SafeTransactionData format
        transactions.push({
            to: REV_SHARE_MODULE_ADDRESS,
            value: "0",
            data,
            operation: 0, // 0 = CALL
            baseGas: "0",
            gasPrice: "0",
            gasToken: "0x0000000000000000000000000000000000000000",
            refundReceiver: "0x0000000000000000000000000000000000000000",
            safeTxGas: "0",
            nonce: 0, // Ignore nonce; Transaction Builder will set it // todo: confirm
        })
    }

    console.log(
        `Constructed ${transactions.length} adminBackfillRevenue txs to RevShareModule (${REV_SHARE_MODULE_ADDRESS})`,
    )

    // JSON batch in Transaction Builder format
    // Example schema: see "Safe UI Transaction Batch Schema" on Ethereum SE
    const batchJson = {
        version: "1.0",
        chainId: SAFE_CHAIN_ID,
        createdAt: Date.now(),
        meta: {
            name: "RevShare backfill",
            description: `Backfill allocations for ${allocations.length} addresses (batch size ${BATCH_SIZE})`,
            txBuilderVersion: "1.17.1",
            createdFromSafeAddress: SAFE_ADDRESS,
            createdFromOwnerAddress: "",
            // checksum: opcional; el Transaction Builder la recalcula internamente
        },
        transactions,
    }

    fs.writeFileSync(OUT_SAFE_JSON, JSON.stringify(batchJson, null, 2), "utf8")
    console.log(`Safe batch JSON written to: ${OUT_SAFE_JSON}`)
    console.log("You can now import this file in Safe > Transaction Builder.")
}

main().catch((err) => {
    console.error("Error while building Safe batch JSON:")
    console.error(err)
    process.exit(1)
})
