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

// Todo: Change this to the real total retro amount you want to distribute.
const TOTAL_BACKFILL_TOKENS = "100000" // in human units, e.g. "100000" means 100,000 usdc

// Pioneers' share in basis points (75% = 7500 bps)
const PIONEERS_SHARE_BPS = 7500

// Name used in AddressManager for Takadao revenue receiver
const REVENUE_RECEIVER_KEY = "REVENUE_RECEIVER"

const ARBITRUM_MAINNET_RPC_URL = process.env.ARBITRUM_MAINNET_RPC_URL

// AddressManager deployment (Arbitrum One)
const ADDRESS_MANAGER_ABI = addressManagerDeployment.abi
const ADDRESS_MANAGER_ADDRESS = addressManagerDeployment.address

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
    console.log("=== Build RevShare backfill allocations ===")

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

    // 1) Compute total NFTs from the pioneers file
    let totalNfts = 0n
    for (const p of pioneers) {
        totalNfts += BigInt(p.nftBalance)
    }

    console.log(`Total NFTs from pioneers map: ${totalNfts.toString()}`)

    if (pioneersJson.totalNftsFromMap) {
        const fromFile = BigInt(pioneersJson.totalNftsFromMap)
        if (fromFile !== totalNfts) {
            console.warn(
                `Warning: totalNftsFromMap (${fromFile}) != recomputed totalNfts (${totalNfts})`,
            )
        }
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

    // 4) Per-address pioneer allocations (pro-rata by NFT balance)
    const rows = [...pioneers].sort((a, b) => a.address.localeCompare(b.address))

    const allocations = []
    let sumPioneersAlloc = 0n

    for (const p of rows) {
        const addr = String(p.address).toLowerCase()
        const bal = BigInt(p.nftBalance)

        if (bal === 0n) continue

        // Base share = floor(PB * bal / totalNfts)
        const amount = (pioneersBackfillRaw * bal) / totalNfts

        allocations.push({
            address: addr,
            amountRaw: amount.toString(),
        })

        sumPioneersAlloc += amount
    }

    // Rounding adjustment so sum(allocations) == pioneersBackfillRaw
    let delta = pioneersBackfillRaw - sumPioneersAlloc

    console.log(
        `Sum of pioneers allocations BEFORE delta: ${sumPioneersAlloc.toString()} raw ` +
            `(expected ${pioneersBackfillRaw.toString()})`,
    )
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

    // 6) Fetch REVENUE_RECEIVER from AddressManager via ethers
    let revenueReceiver = null

    if (!ARBITRUM_MAINNET_RPC_URL) {
        console.warn(
            "Warning: ARBITRUM_MAINNET_RPC_URL not set in .env. " +
                "Skipping Takadao allocation entry, please set them and rerun if you want it included.",
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

    // 7) Final sanity check: total allocations vs TOTAL_BACKFILL_RAW
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

    // informational per-NFT amount (not used for allocation math)
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

    console.log("Done building backfill allocations.")
}

// Run main
main().catch((err) => {
    console.error("Error while building backfill allocations:")
    console.error(err)
    process.exit(1)
})
