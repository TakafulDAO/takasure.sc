require("dotenv").config()
const { ethers } = require("ethers")
const fs = require("fs")
const path = require("path")
const addressManagerDeployment = require("../../deployments/mainnet_arbitrum_one/AddressManager.json")

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

// Input from previous script
const PIONEERS_FILE = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/pioneers/revshare_pioneers.json",
)

// Outputs
const OUT_JSON = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.json",
)
const OUT_CSV = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.csv",
)

// Backfill configuration
// USDC decimals
const TOKEN_DECIMALS = 6

// Todo: Change this to the real amount
const TOTAL_BACKFILL_TOKENS = "100000" // in human units, "100000" means 100,000 USDC

// Pioneers' share in basis points (75% = 7500 bps)
const PIONEERS_SHARE_BPS = 7500

// Time-weighting configuration (UNIX timestamps in seconds)
// ! For now, approximate to:
//  - Tranche 1 joined on 2025-06-01
//  - Tranche 2 joined on 2025-09-01
//  - Backfill is measured up to BACKFILL_END_TS
// You can adjust these when you confirm dates with your CTO.
const TRANCHE_1_START_TS = Math.floor(new Date("2025-06-01T00:00:00Z").getTime() / 1000)
const TRANCHE_2_START_TS = Math.floor(new Date("2025-09-01T00:00:00Z").getTime() / 1000)
// Placeholder "end of backfill" timestamp
// ! This must be the deployment date of the RevShare module contract
const BACKFILL_END_TS = Math.floor(new Date("2025-12-01T00:00:00Z").getTime() / 1000)

// Name used in AddressManager for Takadao revenue receiver
const REVENUE_RECEIVER_KEY = "REVENUE_RECEIVER"

const ARBITRUM_MAINNET_RPC_URL = process.env.ARBITRUM_MAINNET_RPC_URL // Arbitrum One RPC URL
// const RPC_URL = "http://127.0.0.1:8545" // Anvil RPC URL

// AddressManager deployment (Arbitrum One)
const ADDRESS_MANAGER_ABI = addressManagerDeployment.abi
const ADDRESS_MANAGER_ADDRESS =
    process.env.ADDRESS_MANAGER_ADDRESS && process.env.ADDRESS_MANAGER_ADDRESS !== "0x"
        ? process.env.ADDRESS_MANAGER_ADDRESS
        : addressManagerDeployment.address

/*//////////////////////////////////////////////////////////////
                                HELPERS
//////////////////////////////////////////////////////////////*/

/**
 * Parse a human-readable amount into raw units using decimals.
 * e.g. ("1.5", 6) => 1500000n
 */
function parseAmountToRaw(amountStr, decimals) {
    if (typeof amountStr !== "string") {
        throw new Error("amountStr must be a string")
    }
    const [intPart, fracPartRaw] = amountStr.split(".")

    const fracPart = fracPartRaw || ""
    if (fracPart.length > decimals) {
        throw new Error(`Too many decimal places in ${amountStr}, max is ${decimals}`)
    }

    const intBig = BigInt(intPart || "0")
    const fracPadded = fracPart.padEnd(decimals, "0")
    const fracBig = BigInt(fracPadded || "0")

    const base = BigInt(10) ** BigInt(decimals)
    return intBig * base + fracBig
}

/**
 * Format a BigInt amount in raw units into human string (for logs only).
 */
function formatRaw(amountRaw, decimals) {
    const base = BigInt(10) ** BigInt(decimals)
    const intPart = amountRaw / base
    const fracPart = amountRaw % base
    if (fracPart === 0n) return intPart.toString()

    const fracStr = fracPart.toString().padStart(decimals, "0").replace(/0+$/, "")
    return `${intPart.toString()}.${fracStr}`
}

async function main() {
    console.log("=== Build RevShare backfill allocations (time-weighted by tranche) ===")

    if (!fs.existsSync(PIONEERS_FILE)) {
        throw new Error(
            `Pioneers file not found at ${PIONEERS_FILE}. Run 01-exportRevSharePioneers first.`,
        )
    }

    const pioneersJson = JSON.parse(fs.readFileSync(PIONEERS_FILE, "utf8"))
    const pioneers = pioneersJson.pioneers || []

    if (pioneers.length === 0) {
        throw new Error("No pioneers found in revshare_pioneers.json")
    }

    console.log(`Loaded ${pioneers.length} pioneers from ${PIONEERS_FILE}`)

    // 1) Compute total NFTs from the pioneers file (current total supply at snapshot)
    let totalNfts = 0n
    let totalNftsTranche1 = 0n

    const rows = [...pioneers].map((p) => {
        const addr = String(p.address).toLowerCase()
        const bal = BigInt(p.nftBalance)
        const tranche = Number(p.tranche || 0)

        totalNfts += bal
        if (tranche === 1) {
            totalNftsTranche1 += bal
        }

        return {
            address: addr,
            nftBalance: bal,
            tranche,
        }
    })

    console.log(`Total NFTs from pioneers map: ${totalNfts.toString()}`)
    console.log(`Total NFTs in tranche 1:       ${totalNftsTranche1.toString()}`)

    if (pioneersJson.totalNftsFromMap) {
        const fromFile = BigInt(pioneersJson.totalNftsFromMap)
        if (fromFile !== totalNfts) {
            console.warn(
                `Warning: totalNftsFromMap (${fromFile}) != recomputed totalNfts (${totalNfts})`,
            )
        }
    }

    if (totalNftsTranche1 === 0n) {
        throw new Error("totalNftsTranche1 is zero – tranche 1 must contain some NFTs")
    }

    // 2) Compute TOTAL_BACKFILL in raw units
    const TOTAL_BACKFILL_RAW = parseAmountToRaw(TOTAL_BACKFILL_TOKENS, TOKEN_DECIMALS)
    console.log(
        `TOTAL_BACKFILL: ${TOTAL_BACKFILL_TOKENS} tokens = ${TOTAL_BACKFILL_RAW.toString()} raw`,
    )

    // 3) Split 75/25 between pioneers and Takadao
    const pioneersBackfillRaw = (TOTAL_BACKFILL_RAW * BigInt(PIONEERS_SHARE_BPS)) / 10000n
    const takadaoBackfillRaw = TOTAL_BACKFILL_RAW - pioneersBackfillRaw

    console.log(
        `Pioneers share (${PIONEERS_SHARE_BPS / 100}%) raw: ${pioneersBackfillRaw.toString()} ` +
            `(~${formatRaw(pioneersBackfillRaw, TOKEN_DECIMALS)} tokens)`,
    )
    console.log(
        `Takadao share (~${100 - PIONEERS_SHARE_BPS / 100}%) raw: ${takadaoBackfillRaw.toString()} ` +
            `(~${formatRaw(takadaoBackfillRaw, TOKEN_DECIMALS)} tokens)`,
    )

    // 4) Time-weighting between two segments:
    //    Segment 1: [TRANCHE_1_START_TS, TRANCHE_2_START_TS) — only tranche 1 participates, supply = totalNftsTranche1
    //    Segment 2: [TRANCHE_2_START_TS, BACKFILL_END_TS]    — both tranches participate, supply = totalNfts (current total supply)
    if (!(TRANCHE_1_START_TS < TRANCHE_2_START_TS && TRANCHE_2_START_TS < BACKFILL_END_TS)) {
        throw new Error(
            "Time config invalid: require TRANCHE_1_START_TS < TRANCHE_2_START_TS < BACKFILL_END_TS",
        )
    }

    const seg1DurationSec = BigInt(TRANCHE_2_START_TS - TRANCHE_1_START_TS)
    const seg2DurationSec = BigInt(BACKFILL_END_TS - TRANCHE_2_START_TS)
    const totalDurationSec = seg1DurationSec + seg2DurationSec

    console.log(
        `Segment 1 duration (sec): ${seg1DurationSec.toString()} | Segment 2 duration (sec): ${seg2DurationSec.toString()}`,
    )

    const segment1Pot = (pioneersBackfillRaw * seg1DurationSec) / totalDurationSec
    const segment2Pot = pioneersBackfillRaw - segment1Pot

    console.log(
        `Segment 1 pot (tranche 1 only): ${segment1Pot.toString()} (~${formatRaw(
            segment1Pot,
            TOKEN_DECIMALS,
        )})`,
    )
    console.log(
        `Segment 2 pot (both tranches):  ${segment2Pot.toString()} (~${formatRaw(
            segment2Pot,
            TOKEN_DECIMALS,
        )})`,
    )

    // 5) Per-address pioneer allocations (time-weighted)
    // For tranche 1:
    //   - Part from segment 1: segment1Pot * bal / totalNftsTranche1
    //   - Part from segment 2: segment2Pot * bal / totalNfts
    // For tranche 2:
    //   - Only segment 2:      segment2Pot * bal / totalNfts

    // Sort rows by address for deterministic output
    rows.sort((a, b) => a.address.localeCompare(b.address))

    const allocations = []
    let sumPioneersAlloc = 0n

    for (const p of rows) {
        const bal = p.nftBalance
        if (bal === 0n) continue

        let amt = 0n

        if (p.tranche === 1) {
            // Segment 1 share (only tranche 1, supply = totalNftsTranche1)
            amt += (segment1Pot * bal) / totalNftsTranche1
            // Segment 2 share (all NFTs)
            amt += (segment2Pot * bal) / totalNfts
        } else if (p.tranche === 2) {
            // Only segment 2
            amt += (segment2Pot * bal) / totalNfts
        } else {
            // If tranche not set, default to tranche 2 behavior (conservative)
            amt += (segment2Pot * bal) / totalNfts
        }

        allocations.push({
            address: p.address,
            amountRaw: amt.toString(),
        })

        sumPioneersAlloc += amt
    }

    console.log(
        `Sum of pioneers allocations BEFORE delta: ${sumPioneersAlloc.toString()} raw ` +
            `(expected ${pioneersBackfillRaw.toString()})`,
    )

    // 6) Global rounding adjustment so sum(allocations) == pioneersBackfillRaw
    let delta = pioneersBackfillRaw - sumPioneersAlloc
    console.log(`Delta to distribute (raw units): ${delta.toString()}`)

    // Distribute +1 raw unit to the first `delta` addresses
    for (let i = 0; delta > 0n && i < allocations.length; i++) {
        const a = allocations[i]
        const newAmount = BigInt(a.amountRaw) + 1n
        a.amountRaw = newAmount.toString()
        delta -= 1n
    }

    if (delta !== 0n) {
        throw new Error(`Delta should be zero after adjustment, got: ${delta.toString()}`)
    }

    // Recompute sum to be safe
    sumPioneersAlloc = 0n
    for (const a of allocations) {
        sumPioneersAlloc += BigInt(a.amountRaw)
    }

    console.log(
        `Sum of pioneers allocations AFTER delta: ${sumPioneersAlloc.toString()} raw ` +
            `(expected ${pioneersBackfillRaw.toString()})`,
    )

    if (sumPioneersAlloc !== pioneersBackfillRaw) {
        throw new Error(
            "Sum of pioneers allocations does not equal pioneersBackfillRaw after adjustment!",
        )
    }

    // 7) Fetch REVENUE_RECEIVER from AddressManager
    let revenueReceiver = null

    if (!ARBITRUM_MAINNET_RPC_URL) {
        console.warn(
            "Warning: ARBITRUM_MAINNET_RPC_URL not set in .env. " +
                "Skipping Takadao allocation entry, please set it and rerun if you want it included.",
        )
    } else if (!ADDRESS_MANAGER_ADDRESS || ADDRESS_MANAGER_ADDRESS === "0x") {
        console.warn(
            "Warning: ADDRESS_MANAGER_ADDRESS is missing or '0x'. " +
                "Skipping Takadao allocation entry; this is expected before you deploy AddressManager.",
        )
    } else {
        console.log(`Connecting to AddressManager at ${ADDRESS_MANAGER_ADDRESS}`)
        const provider = new ethers.providers.JsonRpcProvider(ARBITRUM_MAINNET_RPC_URL)
        const addressManager = new ethers.Contract(
            ADDRESS_MANAGER_ADDRESS,
            ADDRESS_MANAGER_ABI,
            provider,
        )

        const protocolAddress = await addressManager.getProtocolAddressByName(REVENUE_RECEIVER_KEY)
        // Struct: { name: bytes32, addr: address, addressType: uint8 }
        revenueReceiver = (protocolAddress.addr || protocolAddress[1]).toLowerCase()

        console.log(`REVENUE_RECEIVER resolved to: ${revenueReceiver}`)

        // Add Takadao allocation
        allocations.push({
            address: revenueReceiver,
            amountRaw: takadaoBackfillRaw.toString(),
        })
    }

    // 8) Final sanity check: total allocations vs TOTAL_BACKFILL_RAW
    let sumAllAlloc = 0n
    for (const a of allocations) {
        sumAllAlloc += BigInt(a.amountRaw)
    }

    console.log(
        `Sum of ALL allocations: ${sumAllAlloc.toString()} raw ` +
            `(expected ${TOTAL_BACKFILL_RAW.toString()})`,
    )

    if (sumAllAlloc !== TOTAL_BACKFILL_RAW) {
        console.warn(
            "Warning: Sum of allocations does not equal TOTAL_BACKFILL_RAW. " +
                "If you skipped Takadao, this is expected; otherwise, check config.",
        )
    }

    /*//////////////////////////////////////////////////////////////
                               WRITE JSON
    //////////////////////////////////////////////////////////////*/

    // informational global per-NFT amount (not used for allocation math)
    const perNftRaw = pioneersBackfillRaw / totalNfts
    console.log(
        `Per-NFT (informational) = ${perNftRaw.toString()} raw ` +
            `(~${formatRaw(perNftRaw, TOKEN_DECIMALS)} tokens)`,
    )

    const outputJson = {
        snapshotBlock: pioneersJson.snapshotBlock ?? null,
        tokenDecimals: TOKEN_DECIMALS,
        totalBackfillTokens: TOTAL_BACKFILL_TOKENS,
        totalBackfillRaw: TOTAL_BACKFILL_RAW.toString(),
        pioneersBackfillRaw: pioneersBackfillRaw.toString(),
        takadaoBackfillRaw: takadaoBackfillRaw.toString(),
        totalNfts: totalNfts.toString(),
        totalNftsTranche1: totalNftsTranche1.toString(),
        tranche1StartTs: TRANCHE_1_START_TS,
        tranche2StartTs: TRANCHE_2_START_TS,
        backfillEndTs: BACKFILL_END_TS,
        perNftRaw: perNftRaw.toString(),
        pioneersCount: pioneers.length,
        allocations,
    }

    fs.writeFileSync(OUT_JSON, JSON.stringify(outputJson, null, 2), "utf8")
    console.log(`JSON written to: ${OUT_JSON}`)

    /*//////////////////////////////////////////////////////////////
                               WRITE CSV
    //////////////////////////////////////////////////////////////*/

    const csvLines = []
    csvLines.push("address,amountRaw")

    for (const a of allocations) {
        csvLines.push(`${a.address},${a.amountRaw}`)
    }

    fs.writeFileSync(OUT_CSV, csvLines.join("\n"), "utf8")
    console.log(`CSV written to:  ${OUT_CSV}`)

    console.log("Done building backfill allocations (time-weighted).")
}

// Run main
main().catch((err) => {
    console.error("Error while building backfill allocations:")
    console.error(err)
    process.exit(1)
})
