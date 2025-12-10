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

// Outputs
const OUT_CALLDATA_JSON = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/calldata/revshare_backfill_calldata.json",
)
const OUT_CALLDATA_CSV = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/calldata/revshare_backfill_calldata.csv",
)

// RevShareModule deployment (Arbitrum One)
const REV_SHARE_MODULE_ADDRESS = revShareModuleDeployment.address
const REV_SHARE_MODULE_ABI = revShareModuleDeployment.abi

// Batch size for adminBackfillRevenue
const BATCH_SIZE = parseInt(process.env.BACKFILL_BATCH_SIZE || "20", 10)

/*//////////////////////////////////////////////////////////////
                                HELPERS
//////////////////////////////////////////////////////////////*/

function formatRaw(amountRaw, decimals) {
    const base = BigInt(10) ** BigInt(decimals)
    const intPart = amountRaw / base
    const fracPart = amountRaw % base
    if (fracPart === 0n) return intPart.toString()

    const fracStr = fracPart.toString().padStart(decimals, "0").replace(/0+$/, "")
    return `${intPart.toString()}.${fracStr}`
}

/*//////////////////////////////////////////////////////////////
                                 MAIN
//////////////////////////////////////////////////////////////*/

async function main() {
    console.log("=== Build RevShare backfill calldata per batch ===")

    if (!REV_SHARE_MODULE_ADDRESS || !REV_SHARE_MODULE_ABI) {
        throw new Error("RevShareModule deployment JSON must have address and abi")
    }

    if (!fs.existsSync(ALLOCATIONS_FILE)) {
        throw new Error(
            `Allocations file not found at ${ALLOCATIONS_FILE}. Run buildRevShareBackfillAllocations first.`,
        )
    }

    const allocationsJson = JSON.parse(fs.readFileSync(ALLOCATIONS_FILE, "utf8"))
    const allocations = allocationsJson.allocations || []
    const tokenDecimals = allocationsJson.tokenDecimals

    if (!Number.isInteger(tokenDecimals)) {
        throw new Error("tokenDecimals missing or not an integer in allocations JSON")
    }

    if (allocations.length === 0) {
        throw new Error("No allocations found in revshare_backfill_allocations.json")
    }

    console.log(
        `Loaded ${allocations.length} allocations (addresses), tokenDecimals = ${tokenDecimals}`,
    )
    console.log(`Using BATCH_SIZE = ${BATCH_SIZE}`)
    console.log(`RevShareModule: ${REV_SHARE_MODULE_ADDRESS}`)

    const iface = new ethers.utils.Interface(REV_SHARE_MODULE_ABI)

    const batches = []
    const csvLines = []

    // CSV header
    csvLines.push("batchIndex,to,numAddresses,sumRaw,sumTokens,calldata")

    for (let i = 0; i < allocations.length; i += BATCH_SIZE) {
        const slice = allocations.slice(i, i + BATCH_SIZE)
        const batchIndex = Math.floor(i / BATCH_SIZE)

        const accounts = slice.map((a) => String(a.address).toLowerCase())
        const amounts = slice.map((a) => a.amountRaw)

        if (accounts.length === 0) continue
        if (accounts.length !== amounts.length) {
            throw new Error(`accounts.length !== amounts.length in batch ${batchIndex}`)
        }

        // Sum for this batch (raw + human)
        let sumRaw = 0n
        for (const a of slice) {
            sumRaw += BigInt(a.amountRaw)
        }
        const sumTokens = formatRaw(sumRaw, tokenDecimals)

        // Encode calldata
        const calldata = iface.encodeFunctionData("adminBackfillRevenue", [accounts, amounts])

        batches.push({
            batchIndex,
            to: REV_SHARE_MODULE_ADDRESS,
            numAddresses: accounts.length,
            sumRaw: sumRaw.toString(),
            sumTokens,
            accounts,
            amounts,
            calldata,
        })

        csvLines.push(
            [
                batchIndex,
                REV_SHARE_MODULE_ADDRESS,
                accounts.length,
                sumRaw.toString(),
                sumTokens,
                calldata,
            ].join(","),
        )
    }

    console.log(`Built calldata for ${batches.length} batches.`)

    // JSON output
    const jsonOutput = {
        revShareModule: REV_SHARE_MODULE_ADDRESS,
        batchSize: BATCH_SIZE,
        tokenDecimals,
        totalBatches: batches.length,
        batches,
    }

    fs.writeFileSync(OUT_CALLDATA_JSON, JSON.stringify(jsonOutput, null, 2), "utf8")
    console.log(`Calldata JSON written to: ${OUT_CALLDATA_JSON}`)

    // CSV output
    fs.writeFileSync(OUT_CALLDATA_CSV, csvLines.join("\n"), "utf8")
    console.log(`Calldata CSV written to: ${OUT_CALLDATA_CSV}`)

    console.log("Done building RevShare backfill calldata.")
}

main().catch((err) => {
    console.error("Error while building RevShare backfill calldata:")
    console.error(err)
    process.exit(1)
})
