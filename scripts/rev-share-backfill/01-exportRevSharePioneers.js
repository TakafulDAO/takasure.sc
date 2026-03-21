const fetch = require("node-fetch")
const fs = require("fs")
const path = require("path")
require("dotenv").config()

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

const ARBITRUM_ONE_CHAIN_ID = 42161
const ARBITRUM_SEPOLIA_CHAIN_ID = 421614
const CHAIN_FLAG_TO_ID = {
    "arb-one": ARBITRUM_ONE_CHAIN_ID,
    "arb-sep": ARBITRUM_SEPOLIA_CHAIN_ID,
}

// Entities per page
const PAGE_SIZE = 1000
const TOKEN_BATCH_SIZE = 200

// `undefined` means latest block.
const SNAPSHOT_BLOCK = undefined // e.g. 246000000

/*//////////////////////////////////////////////////////////////
                            GRAPHQL QUERIES
//////////////////////////////////////////////////////////////*/

const QUERY = `
  query Pioneers($first: Int!, $skip: Int!, $block: Block_height) {
    pioneers(first: $first, skip: $skip, where: { balance_gt: 0 }, block: $block) {
      pioneerAddress
      balance
      idsOwned
    }
    globalNftStat(id: "global", block: $block) {
      currentSupply
      totalUniquePioneers
    }
  }
`

const TRANSFERS_QUERY = `
  query Transfers($first: Int!, $skip: Int!, $tokenIds: [BigInt!]!, $block: Block_height) {
    transfers(
      first: $first
      skip: $skip
      where: { tokenId_in: $tokenIds }
      orderBy: blockNumber
      orderDirection: desc
      block: $block
    ) {
      tokenId
      to
      blockNumber
      blockTimestamp
    }
  }
`

const SINGLE_MINTS_QUERY = `
  query SingleMints($first: Int!, $skip: Int!, $tokenIds: [BigInt!]!, $block: Block_height) {
    onRevShareNFTMinteds(first: $first, skip: $skip, where: { tokenId_in: $tokenIds }, block: $block) {
      pioneer
      tokenId
      blockTimestamp
    }
  }
`

const BATCH_MINTS_QUERY = `
  query BatchMints($first: Int!, $skip: Int!, $block: Block_height) {
    onBatchRevShareNFTMinteds(
      first: $first
      skip: $skip
      orderBy: blockTimestamp
      orderDirection: desc
      block: $block
    ) {
      pioneer
      initialTokenId
      lastTokenId
      blockTimestamp
    }
  }
`

/*//////////////////////////////////////////////////////////////
                                HELPERS
//////////////////////////////////////////////////////////////*/

function normalizeAddress(address) {
    return String(address).toLowerCase()
}

function logSection(title) {
    console.log(`\n=== ${title} ===`)
}

function chunkArray(values, chunkSize) {
    const chunks = []

    for (let i = 0; i < values.length; i += chunkSize) {
        chunks.push(values.slice(i, i + chunkSize))
    }

    return chunks
}

function chainName(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) return "arbitrum-one"
    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) return "arbitrum-sepolia"
    return `unsupported-${chainId}`
}

function chainFlagName(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) return "arb-one"
    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) return "arb-sep"
    return "unsupported"
}

function outputScopeName(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) return "mainnet"
    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) return "testnet"
    throw new Error(`Unsupported chainId for output scope: ${chainId}`)
}

function buildOutputPaths(chainId) {
    const outputRoot = path.join(
        process.cwd(),
        "scripts/rev-share-backfill/output",
        outputScopeName(chainId),
    )

    return {
        outputRoot,
        json: path.join(outputRoot, "pioneers", "revshare_pioneers.json"),
        csv: path.join(outputRoot, "pioneers", "revshare_pioneers.csv"),
    }
}

function printHelp() {
    console.log(`RevShare pioneers exporter

Exports current RevShare NFT holders ("pioneers") from the refAndNft subgraph.

Output files:
- arb-one -> scripts/rev-share-backfill/output/mainnet/pioneers/revshare_pioneers.json
- arb-one -> scripts/rev-share-backfill/output/mainnet/pioneers/revshare_pioneers.csv
- arb-sep -> scripts/rev-share-backfill/output/testnet/pioneers/revshare_pioneers.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/pioneers/revshare_pioneers.csv

Per pioneer, the script writes:
- address
- nftBalance
- holdingSince

holdingSince semantics:
- Earliest latest-acquisition timestamp across the NFTs currently held by the address.

Flags:
- --chain <arb-one|arb-sep>  Select Arbitrum One or Arbitrum Sepolia
- --help                     Show this help message

Subgraph mapping:
- arb-one -> MAINNET_SUBGRAPH_URL
- arb-sep -> TESTNET_SUBGRAPH_URL

Examples:
- node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain arb-one
- node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain arb-sep
`)
}

function parseArgs(argv) {
    const parsed = {
        chainId: null,
        showHelp: false,
    }

    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i]

        if (arg === "--help") {
            parsed.showHelp = true
            continue
        }

        if (arg === "--chain") {
            const value = argv[i + 1]
            if (!value) {
                throw new Error("Missing value for --chain. Expected arb-one or arb-sep.")
            }

            const chainId = CHAIN_FLAG_TO_ID[value]
            if (!chainId) {
                throw new Error(`Invalid --chain value: ${value}. Expected arb-one or arb-sep.`)
            }

            parsed.chainId = chainId
            i += 1
            continue
        }

        throw new Error(`Unknown argument: ${arg}. Use --help to see supported flags.`)
    }

    return parsed
}

function resolveSubgraphUrl(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) {
        if (!process.env.MAINNET_SUBGRAPH_URL) {
            throw new Error("MAINNET_SUBGRAPH_URL environment variable is not set.")
        }

        return process.env.MAINNET_SUBGRAPH_URL
    }

    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) {
        if (!process.env.TESTNET_SUBGRAPH_URL) {
            throw new Error("TESTNET_SUBGRAPH_URL environment variable is not set.")
        }

        return process.env.TESTNET_SUBGRAPH_URL
    }

    throw new Error(
        `Unsupported chain id ${chainId}. Expected Arbitrum One (${ARBITRUM_ONE_CHAIN_ID}) or Arbitrum Sepolia (${ARBITRUM_SEPOLIA_CHAIN_ID}).`,
    )
}

async function resolveChainId(cliChainId) {
    if (cliChainId === null) {
        throw new Error(
            "Missing required --chain flag. Expected --chain arb-one or --chain arb-sep.",
        )
    }

    return cliChainId
}

async function fetchGraph(subgraphUrl, query, variables) {
    const res = await fetch(subgraphUrl, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            query,
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

async function fetchPioneersPage(subgraphUrl, first, skip, blockNumber) {
    const variables = { first, skip }

    if (typeof blockNumber === "number" && Number.isFinite(blockNumber)) {
        variables.block = { number: blockNumber }
    }

    return fetchGraph(subgraphUrl, QUERY, variables)
}

async function fetchTransfersPage(subgraphUrl, tokenIds, first, skip, blockNumber) {
    const variables = {
        first,
        skip,
        tokenIds,
    }

    if (typeof blockNumber === "number" && Number.isFinite(blockNumber)) {
        variables.block = { number: blockNumber }
    }

    return fetchGraph(subgraphUrl, TRANSFERS_QUERY, variables)
}

async function fetchSingleMintsPage(subgraphUrl, tokenIds, first, skip, blockNumber) {
    const variables = {
        first,
        skip,
        tokenIds,
    }

    if (typeof blockNumber === "number" && Number.isFinite(blockNumber)) {
        variables.block = { number: blockNumber }
    }

    return fetchGraph(subgraphUrl, SINGLE_MINTS_QUERY, variables)
}

async function fetchBatchMintsPage(subgraphUrl, first, skip, blockNumber) {
    const variables = { first, skip }

    if (typeof blockNumber === "number" && Number.isFinite(blockNumber)) {
        variables.block = { number: blockNumber }
    }

    return fetchGraph(subgraphUrl, BATCH_MINTS_QUERY, variables)
}

async function fetchLatestTransferPerToken(subgraphUrl, tokenIds, blockNumber) {
    const latestTransfers = new Map()

    for (const tokenIdChunk of chunkArray(tokenIds, TOKEN_BATCH_SIZE)) {
        const unresolved = new Set(tokenIdChunk)
        let skip = 0

        while (unresolved.size > 0) {
            const data = await fetchTransfersPage(
                subgraphUrl,
                tokenIdChunk,
                PAGE_SIZE,
                skip,
                blockNumber,
            )
            const transfers = data.transfers || []

            for (const transfer of transfers) {
                const tokenId = String(transfer.tokenId)

                if (!latestTransfers.has(tokenId)) {
                    latestTransfers.set(tokenId, {
                        holdingSince: BigInt(transfer.blockTimestamp),
                        currentHolder: normalizeAddress(transfer.to),
                    })
                    unresolved.delete(tokenId)
                }
            }

            if (transfers.length < PAGE_SIZE) {
                break
            }

            skip += PAGE_SIZE
        }
    }

    return latestTransfers
}

async function fetchSingleMintTimestamps(subgraphUrl, tokenIds, blockNumber) {
    const singleMints = new Map()

    for (const tokenIdChunk of chunkArray(tokenIds, TOKEN_BATCH_SIZE)) {
        let skip = 0

        while (true) {
            const data = await fetchSingleMintsPage(
                subgraphUrl,
                tokenIdChunk,
                PAGE_SIZE,
                skip,
                blockNumber,
            )
            const mintEvents = data.onRevShareNFTMinteds || []

            for (const mintEvent of mintEvents) {
                singleMints.set(String(mintEvent.tokenId), {
                    holdingSince: BigInt(mintEvent.blockTimestamp),
                    currentHolder: normalizeAddress(mintEvent.pioneer),
                })
            }

            if (mintEvents.length < PAGE_SIZE) {
                break
            }

            skip += PAGE_SIZE
        }
    }

    return singleMints
}

async function fetchAllBatchMints(subgraphUrl, blockNumber) {
    const batchMints = []
    let skip = 0

    while (true) {
        const data = await fetchBatchMintsPage(subgraphUrl, PAGE_SIZE, skip, blockNumber)
        const events = data.onBatchRevShareNFTMinteds || []

        batchMints.push(...events)

        if (events.length < PAGE_SIZE) {
            break
        }

        skip += PAGE_SIZE
    }

    return batchMints
}

async function resolveMintedAtPerToken(subgraphUrl, tokenIds, blockNumber) {
    const mintedAtPerToken = new Map()

    const singleMintTimestamps = await fetchSingleMintTimestamps(subgraphUrl, tokenIds, blockNumber)
    for (const [tokenId, mintEvent] of singleMintTimestamps.entries()) {
        mintedAtPerToken.set(tokenId, mintEvent.holdingSince)
    }

    const missingTokenIds = tokenIds.filter((tokenId) => !mintedAtPerToken.has(tokenId))
    if (missingTokenIds.length === 0) {
        return mintedAtPerToken
    }

    // Some tokens were created through batch mint events, so resolve them by walking the minted token ranges.
    console.log(
        `Single mint events resolved mintedAt for ${tokenIds.length - missingTokenIds.length} tokens. Resolving ${missingTokenIds.length} batch-minted tokens...`,
    )

    const batchMintEvents = await fetchAllBatchMints(subgraphUrl, blockNumber)
    const missingTokenSet = new Set(missingTokenIds)

    for (const batchMintEvent of batchMintEvents) {
        if (missingTokenSet.size === 0) break

        const initialTokenId = BigInt(batchMintEvent.initialTokenId)
        const lastTokenId = BigInt(batchMintEvent.lastTokenId)
        const mintedAt = BigInt(batchMintEvent.blockTimestamp)

        for (const tokenId of Array.from(missingTokenSet)) {
            const numericTokenId = BigInt(tokenId)
            if (numericTokenId < initialTokenId || numericTokenId > lastTokenId) continue

            mintedAtPerToken.set(tokenId, mintedAt)
            missingTokenSet.delete(tokenId)
        }
    }

    if (missingTokenSet.size > 0) {
        throw new Error(
            `Unable to resolve mintedAt for ${missingTokenSet.size} tokens. Example tokenIds: ${Array.from(
                missingTokenSet,
            )
                .slice(0, 10)
                .join(", ")}`,
        )
    }

    return mintedAtPerToken
}

async function resolveHoldingSincePerToken(subgraphUrl, tokenIds, tokenIdToOwner, blockNumber) {
    const holdingSincePerToken = await fetchLatestTransferPerToken(
        subgraphUrl,
        tokenIds,
        blockNumber,
    )

    const ownerMismatches = []
    for (const [tokenId, entry] of holdingSincePerToken.entries()) {
        const expectedOwner = tokenIdToOwner.get(tokenId)
        if (expectedOwner && entry.currentHolder !== expectedOwner) {
            ownerMismatches.push({ tokenId, expectedOwner, currentHolder: entry.currentHolder })
        }
    }

    if (ownerMismatches.length > 0) {
        throw new Error(
            "Latest transfer owner mismatch for current holders: " +
                JSON.stringify(ownerMismatches.slice(0, 5), null, 2),
        )
    }

    let missingTokenIds = tokenIds.filter((tokenId) => !holdingSincePerToken.has(tokenId))

    if (missingTokenIds.length === 0) {
        return holdingSincePerToken
    }

    console.log(
        `Latest Transfer timestamps were missing for ${missingTokenIds.length} tokens. Falling back to mint events...`,
    )

    const singleMintTimestamps = await fetchSingleMintTimestamps(
        subgraphUrl,
        missingTokenIds,
        blockNumber,
    )
    for (const tokenId of missingTokenIds) {
        const singleMint = singleMintTimestamps.get(tokenId)
        if (!singleMint) continue

        const expectedOwner = tokenIdToOwner.get(tokenId)
        if (expectedOwner && singleMint.currentHolder === expectedOwner) {
            holdingSincePerToken.set(tokenId, singleMint)
        }
    }

    missingTokenIds = tokenIds.filter((tokenId) => !holdingSincePerToken.has(tokenId))
    if (missingTokenIds.length === 0) {
        return holdingSincePerToken
    }

    console.log(
        `Single mint events resolved some tokens, ${missingTokenIds.length} still missing. Falling back to batch mint events...`,
    )

    const batchMintEvents = await fetchAllBatchMints(subgraphUrl, blockNumber)
    const missingTokenSet = new Set(missingTokenIds)

    for (const batchMintEvent of batchMintEvents) {
        if (missingTokenSet.size === 0) break

        const pioneer = normalizeAddress(batchMintEvent.pioneer)
        const initialTokenId = BigInt(batchMintEvent.initialTokenId)
        const lastTokenId = BigInt(batchMintEvent.lastTokenId)
        const mintedAt = BigInt(batchMintEvent.blockTimestamp)

        for (const tokenId of Array.from(missingTokenSet)) {
            const numericTokenId = BigInt(tokenId)
            const expectedOwner = tokenIdToOwner.get(tokenId)

            if (expectedOwner !== pioneer) continue
            if (numericTokenId < initialTokenId || numericTokenId > lastTokenId) continue

            holdingSincePerToken.set(tokenId, {
                holdingSince: mintedAt,
                currentHolder: pioneer,
            })
            missingTokenSet.delete(tokenId)
        }
    }

    if (missingTokenSet.size > 0) {
        throw new Error(
            `Unable to resolve holdingSince for ${missingTokenSet.size} tokens. Example tokenIds: ${Array.from(
                missingTokenSet,
            )
                .slice(0, 10)
                .join(", ")}`,
        )
    }

    return holdingSincePerToken
}

async function main() {
    const cli = parseArgs(process.argv.slice(2))
    if (cli.showHelp) {
        printHelp()
        return
    }

    console.log("=== Export RevShare NFT pioneers from subgraph ===")
    console.log("")

    const chainId = await resolveChainId(cli.chainId)
    const subgraphUrl = resolveSubgraphUrl(chainId)
    const outputPaths = buildOutputPaths(chainId)

    logSection("Configuration")
    console.log(`Resolved chainId: ${chainId} (${chainName(chainId)})`)
    console.log(
        `Using --chain ${chainFlagName(chainId)} -> ${
            chainId === ARBITRUM_ONE_CHAIN_ID ? "MAINNET_SUBGRAPH_URL" : "TESTNET_SUBGRAPH_URL"
        }`,
    )
    console.log(`Writing outputs under: ${outputPaths.outputRoot}`)

    if (typeof SNAPSHOT_BLOCK === "number") {
        console.log(`Using snapshot block: ${SNAPSHOT_BLOCK}`)
    } else {
        console.log("Using latest block.")
    }
    console.log("")

    let allPioneers = []
    let skip = 0
    let globalStats = null

    logSection("Fetch Pioneers")
    while (true) {
        console.log(`Fetching page: first=${PAGE_SIZE}, skip=${skip} ...`)

        const data = await fetchPioneersPage(subgraphUrl, PAGE_SIZE, skip, SNAPSHOT_BLOCK)
        const pioneers = data.pioneers || []

        if (!globalStats && data.globalNftStat) {
            globalStats = {
                currentSupply: BigInt(data.globalNftStat.currentSupply),
                totalUniquePioneers: BigInt(data.globalNftStat.totalUniquePioneers),
            }
        }

        allPioneers = allPioneers.concat(pioneers)
        console.log(`  -> got ${pioneers.length} pioneers (total so far: ${allPioneers.length})`)

        if (pioneers.length < PAGE_SIZE) {
            break
        }

        skip += PAGE_SIZE
    }

    const pioneersMap = new Map()

    for (const pioneerRow of allPioneers) {
        const address = normalizeAddress(pioneerRow.pioneerAddress)
        const balance = BigInt(pioneerRow.balance)
        const idsOwned = Array.isArray(pioneerRow.idsOwned)
            ? pioneerRow.idsOwned.map((tokenId) => String(tokenId))
            : []

        // Merge paginated rows first so each address has one canonical balance and token list before validation.
        const current = pioneersMap.get(address) || {
            balance: 0n,
            idsOwned: [],
        }

        current.balance += balance
        current.idsOwned.push(...idsOwned)

        pioneersMap.set(address, current)
    }

    const tokenIdToOwner = new Map()
    for (const [address, pioneer] of pioneersMap.entries()) {
        pioneer.idsOwned = Array.from(new Set(pioneer.idsOwned)).sort(
            (a, b) => Number(a) - Number(b),
        )

        if (pioneer.idsOwned.length !== Number(pioneer.balance)) {
            throw new Error(
                `idsOwned length mismatch for ${address}. balance=${pioneer.balance.toString()} idsOwned=${pioneer.idsOwned.length}`,
            )
        }

        for (const tokenId of pioneer.idsOwned) {
            tokenIdToOwner.set(tokenId, address)
        }
    }

    const tokenIds = Array.from(tokenIdToOwner.keys())
    console.log("")
    logSection("Resolve Token Timing")
    console.log(
        `Resolving holdingSince timestamps for ${tokenIds.length} currently held token(s) ...`,
    )

    const holdingSincePerToken = await resolveHoldingSincePerToken(
        subgraphUrl,
        tokenIds,
        tokenIdToOwner,
        SNAPSHOT_BLOCK,
    )
    const mintedAtPerToken = await resolveMintedAtPerToken(subgraphUrl, tokenIds, SNAPSHOT_BLOCK)

    const rows = Array.from(pioneersMap.entries()).map(([address, pioneer]) => {
        let holdingSince = null
        const tokens = []

        for (const tokenId of pioneer.idsOwned) {
            const tokenData = holdingSincePerToken.get(tokenId)
            if (!tokenData) {
                throw new Error(`Missing holdingSince for token ${tokenId} owned by ${address}`)
            }
            const mintedAt = mintedAtPerToken.get(tokenId)
            if (mintedAt === undefined) {
                throw new Error(`Missing mintedAt for token ${tokenId} owned by ${address}`)
            }

            if (holdingSince === null || tokenData.holdingSince < holdingSince) {
                holdingSince = tokenData.holdingSince
            }

            tokens.push({
                tokenId,
                mintedAt: mintedAt.toString(),
                holdingSince: tokenData.holdingSince.toString(),
            })
        }

        return {
            address,
            nftBalance: pioneer.balance.toString(),
            holdingSince: holdingSince !== null ? holdingSince.toString() : null,
            tokens,
        }
    })

    rows.sort((a, b) => a.address.localeCompare(b.address))

    let totalNftsFromMap = 0n
    for (const row of rows) {
        totalNftsFromMap += BigInt(row.nftBalance)
    }

    logSection("Summary")
    console.log(`Pioneers with balance > 0: ${rows.length}`)
    console.log(`Total NFTs from map:      ${totalNftsFromMap.toString()}`)

    if (globalStats) {
        console.log(`GlobalNftStat.currentSupply: ${globalStats.currentSupply.toString()}`)
        console.log(
            `GlobalNftStat.totalUniquePioneers: ${globalStats.totalUniquePioneers.toString()}`,
        )
    } else {
        throw new Error(
            "globalNftStat not found in subgraph response. Refusing to write pioneer export.",
        )
    }

    if (totalNftsFromMap !== globalStats.currentSupply) {
        throw new Error(
            `Subgraph consistency check failed: totalNftsFromMap=${totalNftsFromMap.toString()} does not match globalNftStat.currentSupply=${globalStats.currentSupply.toString()}. Refusing to write pioneer export.`,
        )
    }

    const jsonOutput = {
        chainId,
        network: chainName(chainId),
        snapshotBlock: typeof SNAPSHOT_BLOCK === "number" ? SNAPSHOT_BLOCK : null,
        mintedAtSemantics: "timestamp when the token first entered totalSupply",
        holdingSinceSemantics:
            "minimum latest-acquisition timestamp across the NFTs currently held by each address",
        totalNftsFromMap: totalNftsFromMap.toString(),
        totalPioneers: rows.length,
        globalStats: globalStats
            ? {
                  currentSupply: globalStats.currentSupply.toString(),
                  totalUniquePioneers: globalStats.totalUniquePioneers.toString(),
              }
            : null,
        pioneers: rows,
    }

    console.log("")
    logSection("Write Output")
    fs.mkdirSync(path.dirname(outputPaths.json), { recursive: true })
    fs.writeFileSync(outputPaths.json, JSON.stringify(jsonOutput, null, 2), {
        encoding: "utf8",
    })

    console.log(`JSON written to: ${outputPaths.json}`)

    const csvLines = []
    csvLines.push("address,nftBalance,holdingSince")
    for (const row of rows) {
        csvLines.push(`${row.address},${row.nftBalance},${row.holdingSince}`)
    }

    fs.writeFileSync(outputPaths.csv, csvLines.join("\n"), { encoding: "utf8" })

    console.log(`CSV written to:  ${outputPaths.csv}`)
    console.log("")
    console.log("Done.")
}

main().catch((err) => {
    console.error("Error while exporting pioneers:")
    console.error(err)
    process.exit(1)
})
