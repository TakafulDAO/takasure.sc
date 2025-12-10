require("dotenv").config()
const fs = require("fs")
const path = require("path")

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

// Allocations output file
const ALLOCATIONS_FILE = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.json",
)

// Metadata outputs
const OUT_SUMMARY_JSON = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/metadata/revshare_backfill_batches_summary.json",
)
const OUT_SUMMARY_CSV = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/metadata/revshare_backfill_batches_summary.csv",
)
const OUT_DETAILED_CSV = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/metadata/revshare_backfill_batches_detailed.csv",
)

// Batch size for adminBackfillRevenue
const BATCH_SIZE = parseInt(process.env.BACKFILL_BATCH_SIZE || "20", 10)

/*//////////////////////////////////////////////////////////////
                                HELPERS
//////////////////////////////////////////////////////////////*/

/**
 * Format a BigInt amount in raw units into human string (for logs / CSV).
 */
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
    console.log("=== Build RevShare backfill metadata (batches) ===")

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
        `Loaded ${allocations.length} allocations (addresses) with tokenDecimals = ${tokenDecimals}`,
    )
    console.log(`Using BATCH_SIZE = ${BATCH_SIZE}`)

    // Sanity check: total from allocations
    let totalFromAllocations = 0n
    for (const a of allocations) {
        totalFromAllocations += BigInt(a.amountRaw)
    }

    console.log(
        `Total from allocations: ${totalFromAllocations.toString()} raw (~${formatRaw(
            totalFromAllocations,
            tokenDecimals,
        )} tokens)`,
    )

    const batches = []
    const detailedCsvLines = []

    // Detailed CSV header
    detailedCsvLines.push("batchIndex,address,amountRaw,amountTokens")

    for (let i = 0; i < allocations.length; i += BATCH_SIZE) {
        const slice = allocations.slice(i, i + BATCH_SIZE)
        const batchIndex = Math.floor(i / BATCH_SIZE)
        const startIndex = i
        const endIndex = i + slice.length - 1

        let sumRaw = 0n
        for (const a of slice) {
            sumRaw += BigInt(a.amountRaw)
        }

        const sumTokens = formatRaw(sumRaw, tokenDecimals)

        batches.push({
            batchIndex,
            startIndex,
            endIndex,
            numAddresses: slice.length,
            sumRaw: sumRaw.toString(),
            sumTokens,
        })

        // Fill detailed CSV lines
        for (const a of slice) {
            const raw = BigInt(a.amountRaw)
            const human = formatRaw(raw, tokenDecimals)
            detailedCsvLines.push(`${batchIndex},${a.address},${raw.toString()},${human}`)
        }
    }

    console.log(`Built metadata for ${batches.length} batches.`)

    // Summary CSV per batch
    const summaryCsvLines = []
    summaryCsvLines.push("batchIndex,startIndex,endIndex,numAddresses,sumRaw,sumTokens")

    for (const b of batches) {
        summaryCsvLines.push(
            [b.batchIndex, b.startIndex, b.endIndex, b.numAddresses, b.sumRaw, b.sumTokens].join(
                ",",
            ),
        )
    }

    // JSON summary output
    const summaryJson = {
        tokenDecimals,
        batchSize: BATCH_SIZE,
        totalAllocations: allocations.length,
        totalFromAllocationsRaw: totalFromAllocations.toString(),
        totalFromAllocationsTokens: formatRaw(totalFromAllocations, tokenDecimals),
        batches,
    }

    fs.writeFileSync(OUT_SUMMARY_JSON, JSON.stringify(summaryJson, null, 2), "utf8")
    console.log(`Batch summary JSON written to: ${OUT_SUMMARY_JSON}`)

    // CSV summary output
    fs.writeFileSync(OUT_SUMMARY_CSV, summaryCsvLines.join("\n"), "utf8")
    console.log(`Batch summary CSV written to: ${OUT_SUMMARY_CSV}`)

    // CSV detailed output
    fs.writeFileSync(OUT_DETAILED_CSV, detailedCsvLines.join("\n"), "utf8")
    console.log(`Detailed batch CSV written to: ${OUT_DETAILED_CSV}`)

    console.log("Done building RevShare backfill metadata.")
}

main().catch((err) => {
    console.error("Error while building RevShare backfill metadata:")
    console.error(err)
    process.exit(1)
})
