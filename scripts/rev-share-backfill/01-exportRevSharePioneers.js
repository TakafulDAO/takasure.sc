const fetch = require("node-fetch")
const fs = require("fs")
const path = require("path")
require("dotenv").config()

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

// Subgraph URL
const SUBGRAPH_URL = process.env.SUBGRAPH_URL

if (!SUBGRAPH_URL) {
    throw new Error("SUBGRAPH_URL environment variable is not set.")
}

// Entities per page
const PAGE_SIZE = 1000

// `undefined` means latest block.
const SNAPSHOT_BLOCK = undefined // e.g. 246000000n

// Output file paths (relative to repo root)
const OUT_JSON = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/pioneers/revshare_pioneers.json",
)
const OUT_CSV = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/pioneers/revshare_pioneers.csv",
)

/*//////////////////////////////////////////////////////////////
                            GRAPHQL QUERIES
//////////////////////////////////////////////////////////////*/

const QUERY = `
  query Pioneers($first: Int!, $skip: Int!, $block: Block_height) {
    pioneers(first: $first, skip: $skip, where: { balance_gt: 0 }, block: $block) {
      pioneerAddress
      balance
    }
    globalNftStat(id: "global", block: $block) {
      currentSupply
      totalUniquePioneers
    }
  }
`

/*//////////////////////////////////////////////////////////////
                                HELPERS
//////////////////////////////////////////////////////////////*/

/**
 * Fetch one page of pioneers from the subgraph.
 */
async function fetchPioneersPage(first, skip, blockNumber) {
    const variables = { first, skip }

    if (typeof blockNumber === "number" && Number.isFinite(blockNumber)) {
        variables.block = { number: blockNumber }
    }

    const res = await fetch(SUBGRAPH_URL, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            query: QUERY,
            variables,
        }),
    })

    if (!res.ok) {
        const text = await res.text()
        throw new Error(`Subgraph HTTP error: ${res.status} ${res.statusText}\n${text}`)
    }

    const json = await res.json()

    if (json.errors && json.errors.length > 0) {
        throw new Error("Subgraph GraphQL error:\n" + JSON.stringify(json.errors, null, 2))
    }

    return json.data
}

async function main() {
    console.log("=== Export RevShare NFT pioneers from subgraph ===")

    if (typeof SNAPSHOT_BLOCK === "number") {
        console.log(`Using snapshot block: ${SNAPSHOT_BLOCK}`)
    } else {
        console.log("Using latest block (no snapshot block set).")
    }

    let allPioneers = []
    let skip = 0

    let globalStats = null

    // Pagination loop
    while (true) {
        console.log(`Fetching page: first=${PAGE_SIZE}, skip=${skip} ...`)

        const data = await fetchPioneersPage(PAGE_SIZE, skip, SNAPSHOT_BLOCK)

        const pioneers = data.pioneers || []

        // capture global stats from the first page
        if (!globalStats && data.globalNftStat) {
            globalStats = {
                currentSupply: BigInt(data.globalNftStat.currentSupply),
                totalUniquePioneers: BigInt(data.globalNftStat.totalUniquePioneers),
            }
        }

        allPioneers = allPioneers.concat(pioneers)
        console.log(`  → got ${pioneers.length} pioneers (total so far: ${allPioneers.length})`)

        if (pioneers.length < PAGE_SIZE) {
            break // last page
        }

        skip += PAGE_SIZE
    }

    // Normalize & aggregate
    const balancesMap = new Map()

    for (const p of allPioneers) {
        const address = String(p.pioneerAddress).toLowerCase()
        const balance = BigInt(p.balance)

        const prev = balancesMap.get(address) || 0n
        balancesMap.set(address, prev + balance)
    }

    // Build rows array
    const rows = Array.from(balancesMap.entries()).map(([address, balance]) => ({
        address,
        nftBalance: balance.toString(),
    }))

    // Sort by address for deterministic output
    rows.sort((a, b) => a.address.localeCompare(b.address))

    // Assign tranches:
    // ! For now: first half = tranche 1, second half = tranche 2
    const total = rows.length
    const half = Math.floor(total / 2)
    rows.forEach((row, idx) => {
        row.tranche = idx < half ? 1 : 2
    })

    // Compute total NFTs from map and compare with global stats
    let totalNftsFromMap = 0n
    for (const row of rows) {
        totalNftsFromMap += BigInt(row.nftBalance)
    }

    console.log("=== Summary ===")
    console.log(`Pioneers with balance > 0: ${rows.length}`)
    console.log(`Total NFTs from map:      ${totalNftsFromMap.toString()}`)

    if (globalStats) {
        console.log(`GlobalNftStat.currentSupply: ${globalStats.currentSupply.toString()}`)
        console.log(
            `GlobalNftStat.totalUniquePioneers: ${globalStats.totalUniquePioneers.toString()}`,
        )
    } else {
        console.log("Warning: globalNftStat not found in subgraph response.")
    }

    /*//////////////////////////////////////////////////////////////
                               WRITE JSON
    //////////////////////////////////////////////////////////////*/

    const jsonOutput = {
        snapshotBlock: typeof SNAPSHOT_BLOCK === "number" ? SNAPSHOT_BLOCK : null,
        totalNftsFromMap: totalNftsFromMap.toString(),
        totalPioneers: rows.length,
        globalStats: globalStats
            ? {
                  currentSupply: globalStats.currentSupply.toString(),
                  totalUniquePioneers: globalStats.totalUniquePioneers.toString(),
              }
            : null,
        pioneers: rows, // each row: { address, nftBalance, tranche }
    }

    fs.writeFileSync(OUT_JSON, JSON.stringify(jsonOutput, null, 2), {
        encoding: "utf8",
    })

    console.log(`JSON written to: ${OUT_JSON}`)

    /*//////////////////////////////////////////////////////////////
                               WRITE CSV
    //////////////////////////////////////////////////////////////*/

    const csvLines = []
    csvLines.push("address,nftBalance,tranche")
    for (const row of rows) {
        csvLines.push(`${row.address},${row.nftBalance},${row.tranche}`)
    }

    fs.writeFileSync(OUT_CSV, csvLines.join("\n"), { encoding: "utf8" })

    console.log(`CSV written to:  ${OUT_CSV}`)
    console.log("Done.")
}

main().catch((err) => {
    console.error("Error while exporting pioneers:")
    console.error(err)
    process.exit(1)
})
