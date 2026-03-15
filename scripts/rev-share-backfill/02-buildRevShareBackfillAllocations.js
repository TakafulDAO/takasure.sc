require("dotenv").config()
const { ethers } = require("ethers")
const fs = require("fs")
const path = require("path")

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

const ARBITRUM_ONE_CHAIN_ID = 42161
const ARBITRUM_SEPOLIA_CHAIN_ID = 421614
const CHAIN_FLAG_TO_ID = {
    "arb-one": ARBITRUM_ONE_CHAIN_ID,
    "arb-sep": ARBITRUM_SEPOLIA_CHAIN_ID,
}
const WAD = 10n ** 18n

// USDC decimals
const TOKEN_DECIMALS = 6

// Todo: Change this to the real amount
const TOTAL_BACKFILL_TOKENS = "100000" // in human units, "100000" means 100,000 USDC

// Pioneers' share in basis points (75% = 7500 bps)
const PIONEERS_SHARE_BPS = 7500n
const BPS_DENOMINATOR = 10000n

const ADMIN_REVENUE_RECEIVER_KEY = "ADMIN__REVENUE_RECEIVER"

function printHelp() {
    console.log(`RevShare backfill allocation builder

Builds the RevShare backfill allocation output using the same accumulator model as RevShareModule.

Input file:
- arb-one -> scripts/rev-share-backfill/output/mainnet/pioneers/revshare_pioneers.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/pioneers/revshare_pioneers.json

Output files:
- arb-one -> scripts/rev-share-backfill/output/mainnet/allocations/revshare_backfill_allocations.json
- arb-one -> scripts/rev-share-backfill/output/mainnet/allocations/revshare_backfill_allocations.csv
- arb-sep -> scripts/rev-share-backfill/output/testnet/allocations/revshare_backfill_allocations.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/allocations/revshare_backfill_allocations.csv

Revenue receiver behavior:
- Default: resolve ADMIN__REVENUE_RECEIVER from AddressManager
- Test mode: use TESTNET_DEPLOYER_ADDRESS from .env instead

Backfill window:
- Start: earliest token mintedAt found in the pioneer export JSON
- End: current time when the script runs

Flags:
- --chain <arb-one|arb-sep>  Select the input/output directory set
- --test [true|false]  Use TESTNET_DEPLOYER_ADDRESS for the Takadao allocation row. If the value is omitted, true is assumed.
- --help               Show this help message

Examples:
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-one
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-sep --test
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-one --test false
`)
}

function parseBooleanFlagValue(flagName, value) {
    if (value === "true") return true
    if (value === "false") return false

    throw new Error(`Invalid value for ${flagName}: ${value}. Expected true or false.`)
}

function parseArgs(argv) {
    const parsed = {
        chainId: null,
        showHelp: false,
        testMode: false,
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

        if (arg === "--test") {
            const next = argv[i + 1]

            if (!next || next.startsWith("--")) {
                parsed.testMode = true
                continue
            }

            parsed.testMode = parseBooleanFlagValue("--test", next)
            i += 1
            continue
        }

        throw new Error(`Unknown argument: ${arg}. Use --help to see supported flags.`)
    }

    return parsed
}
/*//////////////////////////////////////////////////////////////
                                HELPERS
//////////////////////////////////////////////////////////////*/

function chainName(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) return "arbitrum-one"
    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) return "arbitrum-sepolia"
    return `unsupported-${chainId}`
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
        pioneersJson: path.join(outputRoot, "pioneers", "revshare_pioneers.json"),
        allocationsJson: path.join(outputRoot, "allocations", "revshare_backfill_allocations.json"),
        allocationsCsv: path.join(outputRoot, "allocations", "revshare_backfill_allocations.csv"),
    }
}

function resolveChainId(cliChainId) {
    if (cliChainId === null) {
        throw new Error("Missing required --chain flag. Expected --chain arb-one or --chain arb-sep.")
    }

    return cliChainId
}

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

function formatRaw(amountRaw, decimals) {
    const base = BigInt(10) ** BigInt(decimals)
    const intPart = amountRaw / base
    const fracPart = amountRaw % base

    if (fracPart === 0n) return intPart.toString()

    const fracStr = fracPart.toString().padStart(decimals, "0").replace(/0+$/, "")
    return `${intPart.toString()}.${fracStr}`
}

function normalizeAddress(address) {
    return String(address).toLowerCase()
}

function formatUnixTimestamp(ts) {
    return new Date(ts * 1000).toISOString()
}

function logSection(title) {
    console.log(`\n=== ${title} ===`)
}

function chainConfigFromChainId(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) {
        return {
            network: "arbitrum-one",
            deploymentsDir: "mainnet_arbitrum_one",
            rpcUrl: process.env.ARBITRUM_MAINNET_RPC_URL || "",
        }
    }

    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) {
        return {
            network: "arbitrum-sepolia",
            deploymentsDir: "testnet_arbitrum_sepolia",
            rpcUrl: process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL || "",
        }
    }

    throw new Error(
        `Unsupported chainId ${chainId}. Expected ${ARBITRUM_ONE_CHAIN_ID} or ${ARBITRUM_SEPOLIA_CHAIN_ID}.`
    )
}

function loadAddressManagerDeployment(chainId) {
    const chainCfg = chainConfigFromChainId(chainId)
    const deploymentPath = path.join(
        process.cwd(),
        "deployments",
        chainCfg.deploymentsDir,
        "AddressManager.json",
    )

    if (!fs.existsSync(deploymentPath)) {
        throw new Error(`AddressManager deployment not found at ${deploymentPath}`)
    }

    return JSON.parse(fs.readFileSync(deploymentPath, "utf8"))
}

function deriveBackfillWindow(pioneers) {
    let oldestMintedAt = null

    for (const pioneer of pioneers) {
        const tokens = Array.isArray(pioneer.tokens) ? pioneer.tokens : null
        if (!tokens || tokens.length === 0) continue

        for (const token of tokens) {
            const mintedAt = Number(token.mintedAt)
            if (!Number.isInteger(mintedAt)) {
                throw new Error(`Invalid mintedAt while deriving backfill window for token ${token.tokenId}`)
            }

            if (oldestMintedAt === null || mintedAt < oldestMintedAt) {
                oldestMintedAt = mintedAt
            }
        }
    }

    if (oldestMintedAt === null) {
        throw new Error("Unable to derive backfillStartTs from pioneer export. No token mintedAt values found.")
    }

    const backfillEndTs = Math.floor(Date.now() / 1000)
    if (!(oldestMintedAt < backfillEndTs)) {
        throw new Error(
            `Derived time window is invalid: backfillStartTs=${oldestMintedAt} backfillEndTs=${backfillEndTs}`,
        )
    }

    return {
        backfillStartTs: oldestMintedAt,
        backfillEndTs,
    }
}

function settleAccount(accountState, currentAccumulatorScaled) {
    const paidScaled = accountState.paidAccumulatorScaled
    const deltaScaled = currentAccumulatorScaled - paidScaled

    if (deltaScaled < 0n) {
        throw new Error("Accumulator moved backwards while settling account")
    }

    if (accountState.balance > 0n && deltaScaled > 0n) {
        accountState.revenueRaw += (accountState.balance * deltaScaled) / WAD
    }

    accountState.paidAccumulatorScaled = currentAccumulatorScaled
}

function buildSimulationInputs(pioneers, backfillStartTs, backfillEndTs) {
    const tokenSnapshots = []
    const accountStates = new Map()
    const supplyDeltaByTs = new Map()
    const balanceIncreaseByTs = new Map()
    const checkpoints = new Set([backfillStartTs, backfillEndTs])

    for (const pioneer of pioneers) {
        const address = normalizeAddress(pioneer.address)
        const tokens = Array.isArray(pioneer.tokens) ? pioneer.tokens : null

        if (!tokens || tokens.length === 0) {
            throw new Error(
                `Pioneer ${address} is missing token snapshots. Re-run 01-exportRevSharePioneers.js before script 02.`
            )
        }

        if (tokens.length !== Number(BigInt(pioneer.nftBalance))) {
            throw new Error(
                `Token snapshot count mismatch for ${address}. nftBalance=${pioneer.nftBalance} tokens=${tokens.length}`
            )
        }

        let accountState = accountStates.get(address)
        if (!accountState) {
            accountState = {
                balance: 0n,
                revenueRaw: 0n,
                paidAccumulatorScaled: 0n,
            }
            accountStates.set(address, accountState)
        }

        for (const token of tokens) {
            const tokenId = String(token.tokenId)
            const mintedAt = Number(token.mintedAt)
            const holdingSince = Number(token.holdingSince)

            if (!Number.isInteger(mintedAt) || !Number.isInteger(holdingSince)) {
                throw new Error(`Invalid timestamps for token ${tokenId}`)
            }
            if (mintedAt > holdingSince) {
                throw new Error(
                    `Invalid token timing for token ${tokenId}: mintedAt ${mintedAt} > holdingSince ${holdingSince}`
                )
            }

            tokenSnapshots.push({
                owner: address,
                tokenId,
                mintedAt,
                holdingSince,
            })

            if (mintedAt <= backfillStartTs) {
                // Token already existed at stream start.
            } else if (mintedAt < backfillEndTs) {
                supplyDeltaByTs.set(mintedAt, (supplyDeltaByTs.get(mintedAt) || 0n) + 1n)
                checkpoints.add(mintedAt)
            }

            if (holdingSince <= backfillStartTs) {
                accountState.balance += 1n
            } else if (holdingSince < backfillEndTs) {
                let addressDeltas = balanceIncreaseByTs.get(holdingSince)
                if (!addressDeltas) {
                    addressDeltas = new Map()
                    balanceIncreaseByTs.set(holdingSince, addressDeltas)
                }

                addressDeltas.set(address, (addressDeltas.get(address) || 0n) + 1n)
                checkpoints.add(holdingSince)
            }
        }
    }

    let initialSupply = 0n
    for (const token of tokenSnapshots) {
        if (token.mintedAt <= backfillStartTs) {
            initialSupply += 1n
        }
    }

    return {
        tokenSnapshots,
        accountStates,
        supplyDeltaByTs,
        balanceIncreaseByTs,
        checkpoints: Array.from(checkpoints).sort((a, b) => a - b),
        initialSupply,
    }
}

function simulatePioneerAccrual(pioneersBackfillRaw, pioneers, backfillStartTs, backfillEndTs) {
    if (!(backfillStartTs < backfillEndTs)) {
        throw new Error("Time config invalid: require backfillStartTs < backfillEndTs")
    }

    const {
        accountStates,
        supplyDeltaByTs,
        balanceIncreaseByTs,
        checkpoints,
        initialSupply,
        tokenSnapshots,
    } = buildSimulationInputs(pioneers, backfillStartTs, backfillEndTs)

    const rewardsDuration = BigInt(backfillEndTs - backfillStartTs)
    const rewardRatePioneersScaled = (pioneersBackfillRaw * WAD) / rewardsDuration

    let currentSupply = initialSupply
    let currentAccumulatorScaled = 0n
    let lostWhileSupplyZeroRaw = 0n

    logSection("Simulation")
    console.log(`Simulation checkpoints: ${checkpoints.length}`)
    console.log(`Initial totalSupply at backfillStartTs: ${currentSupply.toString()}`)
    console.log(`Reward duration (sec): ${rewardsDuration.toString()}`)
    console.log(`rewardRatePioneersScaled: ${rewardRatePioneersScaled.toString()}`)

    for (let i = 0; i < checkpoints.length - 1; i++) {
        const checkpointTs = checkpoints[i]
        const nextTs = checkpoints[i + 1]
        const elapsed = BigInt(nextTs - checkpointTs)

        if (elapsed < 0n) {
            throw new Error("Checkpoint order is invalid")
        }

        if (elapsed > 0n) {
            if (currentSupply > 0n) {
                currentAccumulatorScaled += (elapsed * rewardRatePioneersScaled) / currentSupply
            } else {
                lostWhileSupplyZeroRaw += (elapsed * rewardRatePioneersScaled) / WAD
            }
        }

        const balanceIncreases = balanceIncreaseByTs.get(nextTs)
        if (balanceIncreases) {
            for (const [address, increase] of balanceIncreases.entries()) {
                const accountState = accountStates.get(address)
                if (!accountState) {
                    throw new Error(`Missing account state for ${address}`)
                }

                settleAccount(accountState, currentAccumulatorScaled)
                accountState.balance += increase
            }
        }

        const supplyIncrease = supplyDeltaByTs.get(nextTs) || 0n
        currentSupply += supplyIncrease
    }

    for (const accountState of accountStates.values()) {
        settleAccount(accountState, currentAccumulatorScaled)
    }

    const pioneerRevenueStats = Array.from(accountStates.entries()).map(([address, accountState]) => ({
        address,
        amountRaw: accountState.revenueRaw,
    }))

    let highestRevenuePioneer = null
    let lowestRevenuePioneer = null

    for (const pioneerRevenueStat of pioneerRevenueStats) {
        if (!highestRevenuePioneer || pioneerRevenueStat.amountRaw > highestRevenuePioneer.amountRaw) {
            highestRevenuePioneer = pioneerRevenueStat
        }

        if (!lowestRevenuePioneer || pioneerRevenueStat.amountRaw < lowestRevenuePioneer.amountRaw) {
            lowestRevenuePioneer = pioneerRevenueStat
        }
    }

    const allocations = Array.from(accountStates.entries())
        .map(([address, accountState]) => ({
            address,
            amountRaw: accountState.revenueRaw.toString(),
        }))
        .filter((allocation) => BigInt(allocation.amountRaw) > 0n)
        .sort((a, b) => a.address.localeCompare(b.address))

    let pioneersAllocatedRaw = 0n
    for (const allocation of allocations) {
        pioneersAllocatedRaw += BigInt(allocation.amountRaw)
    }

    const pioneersDustRaw = pioneersBackfillRaw - pioneersAllocatedRaw
    if (pioneersDustRaw < 0n) {
        throw new Error("Pioneer allocations exceeded pioneersBackfillRaw")
    }

    const averagePioneerRevenueRaw =
        pioneerRevenueStats.length > 0 ? pioneersAllocatedRaw / BigInt(pioneerRevenueStats.length) : 0n

    return {
        allocations,
        rewardsDuration,
        rewardRatePioneersScaled,
        pioneersAllocatedRaw,
        pioneersDustRaw,
        lostWhileSupplyZeroRaw,
        totalNfts: BigInt(tokenSnapshots.length),
        checkpointsCount: checkpoints.length,
        highestRevenuePioneer: highestRevenuePioneer
            ? {
                  address: highestRevenuePioneer.address,
                  amountRaw: highestRevenuePioneer.amountRaw.toString(),
              }
            : null,
        lowestRevenuePioneer: lowestRevenuePioneer
            ? {
                  address: lowestRevenuePioneer.address,
                  amountRaw: lowestRevenuePioneer.amountRaw.toString(),
              }
            : null,
        averagePioneerRevenueRaw: averagePioneerRevenueRaw.toString(),
        pioneersWithBalanceCount: pioneerRevenueStats.length,
    }
}

async function resolveRevenueReceiver(chainId, testMode) {
    if (testMode) {
        const testRevenueReceiver = process.env.TESTNET_DEPLOYER_ADDRESS || ""

        if (!testRevenueReceiver) {
            throw new Error("TESTNET_DEPLOYER_ADDRESS is required when --test is enabled. Set it in .env and rerun.")
        }

        if (!ethers.utils.isAddress(testRevenueReceiver)) {
            throw new Error("TESTNET_DEPLOYER_ADDRESS is not a valid address. Fix it in .env and rerun.")
        }

        console.log(`Using TESTNET_DEPLOYER_ADDRESS for --test mode: ${testRevenueReceiver}`)
        return normalizeAddress(testRevenueReceiver)
    }

    const chainCfg = chainConfigFromChainId(chainId)
    const addressManagerDeployment = loadAddressManagerDeployment(chainId)
    const addressManagerAddress =
        process.env.ADDRESS_MANAGER_ADDRESS && process.env.ADDRESS_MANAGER_ADDRESS !== "0x"
            ? process.env.ADDRESS_MANAGER_ADDRESS
            : addressManagerDeployment.address

    if (!chainCfg.rpcUrl) {
        throw new Error(
            `RPC URL for ${chainCfg.network} is not configured. Set the matching RPC env var and rerun the script.`,
        )
    }

    if (!addressManagerAddress || addressManagerAddress === "0x") {
        throw new Error("ADDRESS_MANAGER_ADDRESS is missing or invalid. Set it correctly and rerun the script.")
    }

    console.log(`Connecting to AddressManager at ${addressManagerAddress}`)
    const provider = new ethers.providers.JsonRpcProvider(chainCfg.rpcUrl)
    const addressManager = new ethers.Contract(addressManagerAddress, addressManagerDeployment.abi, provider)

    try {
        const protocolAddress = await addressManager.getProtocolAddressByName(ADMIN_REVENUE_RECEIVER_KEY)
        const resolvedAddress = protocolAddress.addr || protocolAddress[1]

        if (!resolvedAddress || resolvedAddress === ethers.constants.AddressZero) {
            throw new Error(
                `ADMIN__REVENUE_RECEIVER is empty in AddressManager ${addressManagerAddress}. Add it first and rerun this script.`,
            )
        }

        return normalizeAddress(resolvedAddress)
    } catch (error) {
        const errorName = error?.errorName || error?.code || error?.message || "UnknownError"
        throw new Error(
            `ADMIN__REVENUE_RECEIVER is not configured in AddressManager ${addressManagerAddress} (${errorName}). Add it first and rerun this script.`,
        )
    }
}

async function main() {
    const cli = parseArgs(process.argv.slice(2))
    if (cli.showHelp) {
        printHelp()
        return
    }

    const chainId = resolveChainId(cli.chainId)
    const outputPaths = buildOutputPaths(chainId)

    console.log("=== Build RevShare backfill allocations (RevShareModule math) ===")
    console.log("")
    logSection("Configuration")
    console.log(`Using output scope: ${outputScopeName(chainId)} (${chainName(chainId)})`)

    if (!fs.existsSync(outputPaths.pioneersJson)) {
        throw new Error(
            `Pioneers file not found at ${outputPaths.pioneersJson}. Run 01-exportRevSharePioneers.js with the same --chain first.`,
        )
    }

    const pioneersJson = JSON.parse(fs.readFileSync(outputPaths.pioneersJson, "utf8"))
    const pioneers = pioneersJson.pioneers || []

    if (pioneers.length === 0) {
        throw new Error("No pioneers found in revshare_pioneers.json")
    }

    const pioneersChainId = Number(pioneersJson.chainId)
    if (!Number.isInteger(pioneersChainId)) {
        throw new Error("Pioneers file is missing a valid chainId")
    }
    if (pioneersChainId !== chainId) {
        throw new Error(
            `Pioneers file chainId ${pioneersChainId} does not match --chain ${chainId}. Use the matching output directory.`,
        )
    }

    const chainCfg = chainConfigFromChainId(chainId)
    console.log(`Loaded ${pioneers.length} pioneers from ${outputPaths.pioneersJson}`)
    console.log(`Using chainId ${chainId} (${chainCfg.network})`)
    console.log(`Test mode: ${cli.testMode ? "enabled" : "disabled"}`)
    console.log("")

    logSection("Backfill Window")
    const { backfillStartTs, backfillEndTs } = deriveBackfillWindow(pioneers)
    console.log(`Derived backfillStartTs: ${backfillStartTs} (${formatUnixTimestamp(backfillStartTs)})`)
    console.log(`Derived backfillEndTs:   ${backfillEndTs} (${formatUnixTimestamp(backfillEndTs)})`)
    console.log("")

    logSection("Revenue Split")
    const totalBackfillRaw = parseAmountToRaw(TOTAL_BACKFILL_TOKENS, TOKEN_DECIMALS)
    console.log(`TOTAL_BACKFILL: ${TOTAL_BACKFILL_TOKENS} tokens = ${totalBackfillRaw.toString()} raw`)

    const pioneersBackfillRaw = (totalBackfillRaw * PIONEERS_SHARE_BPS) / BPS_DENOMINATOR
    const takadaoShareRaw = totalBackfillRaw - pioneersBackfillRaw

    console.log(
        `Pioneers share (75%) raw: ${pioneersBackfillRaw.toString()} (~${formatRaw(
            pioneersBackfillRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )
    console.log(
        `Takadao share (25%) raw: ${takadaoShareRaw.toString()} (~${formatRaw(
            takadaoShareRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )
    console.log("")

    const pioneerSimulation = simulatePioneerAccrual(pioneersBackfillRaw, pioneers, backfillStartTs, backfillEndTs)
    const rewardRateTakadaoScaled = (takadaoShareRaw * WAD) / pioneerSimulation.rewardsDuration
    const takadaoAllocatedRaw =
        (pioneerSimulation.rewardsDuration * rewardRateTakadaoScaled) / WAD
    const takadaoDustRaw = takadaoShareRaw - takadaoAllocatedRaw

    logSection("Allocation Totals")
    console.log(
        `Pioneers allocated raw: ${pioneerSimulation.pioneersAllocatedRaw.toString()} (~${formatRaw(
            pioneerSimulation.pioneersAllocatedRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )
    console.log(
        `Pioneers dust raw:      ${pioneerSimulation.pioneersDustRaw.toString()} (~${formatRaw(
            pioneerSimulation.pioneersDustRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )
    console.log(
        `Takadao allocated raw:  ${takadaoAllocatedRaw.toString()} (~${formatRaw(
            takadaoAllocatedRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )
    console.log(
        `Takadao dust raw:       ${takadaoDustRaw.toString()} (~${formatRaw(
            takadaoDustRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )
    console.log("")

    logSection("Pioneer Revenue Stats")
    if (pioneerSimulation.highestRevenuePioneer) {
        console.log(
            `Highest revenue pioneer: ${pioneerSimulation.highestRevenuePioneer.address} (${formatRaw(
                BigInt(pioneerSimulation.highestRevenuePioneer.amountRaw),
                TOKEN_DECIMALS
            )} USDC)`,
        )
    }
    if (pioneerSimulation.lowestRevenuePioneer) {
        console.log(
            `Lowest revenue pioneer:  ${pioneerSimulation.lowestRevenuePioneer.address} (${formatRaw(
                BigInt(pioneerSimulation.lowestRevenuePioneer.amountRaw),
                TOKEN_DECIMALS
            )} USDC)`,
        )
    }
    console.log(
        `Average pioneer revenue: ${formatRaw(
            BigInt(pioneerSimulation.averagePioneerRevenueRaw),
            TOKEN_DECIMALS
        )} USDC across ${pioneerSimulation.pioneersWithBalanceCount} pioneers`,
    )
    console.log("")

    const allocations = [...pioneerSimulation.allocations]
    logSection("Revenue Receiver")
    const revenueReceiver = await resolveRevenueReceiver(chainId, cli.testMode)
    console.log(`ADMIN__REVENUE_RECEIVER resolved to: ${revenueReceiver}`)
    allocations.push({
        address: revenueReceiver,
        amountRaw: takadaoAllocatedRaw.toString(),
    })

    allocations.sort((a, b) => a.address.localeCompare(b.address))

    let sumAllAlloc = 0n
    for (const allocation of allocations) {
        sumAllAlloc += BigInt(allocation.amountRaw)
    }

    const totalModuleDustRaw = totalBackfillRaw - pioneerSimulation.pioneersAllocatedRaw - takadaoAllocatedRaw

    console.log("")
    logSection("Final Totals")
    console.log(
        `Sum of ALL allocations: ${sumAllAlloc.toString()} raw (~${formatRaw(sumAllAlloc, TOKEN_DECIMALS)} tokens)`
    )
    console.log(
        `Total module-like dust: ${totalModuleDustRaw.toString()} raw (~${formatRaw(
            totalModuleDustRaw,
            TOKEN_DECIMALS
        )} tokens)`
    )

    const outputJson = {
        chainId,
        network: chainCfg.network,
        snapshotBlock: pioneersJson.snapshotBlock ?? null,
        tokenDecimals: TOKEN_DECIMALS,
        totalBackfillTokens: TOTAL_BACKFILL_TOKENS,
        totalBackfillRaw: totalBackfillRaw.toString(),
        backfillStartTs,
        backfillEndTs,
        backfillStartSource: "minimum token.mintedAt from pioneer export",
        backfillEndSource: "current system time at script execution",
        rewardsDurationSec: pioneerSimulation.rewardsDuration.toString(),
        totalNfts: pioneerSimulation.totalNfts.toString(),
        pioneersCount: pioneers.length,
        calculationModel:
            "single notifyNewRevenue at derived backfillStartTs, claim at derived backfillEndTs, with pioneers accrued using RevShareModule per-NFT accumulator checkpoints",
        rewardRatePioneersScaled: pioneerSimulation.rewardRatePioneersScaled.toString(),
        rewardRateTakadaoScaled: rewardRateTakadaoScaled.toString(),
        pioneersBackfillRaw: pioneersBackfillRaw.toString(),
        pioneersAllocatedRaw: pioneerSimulation.pioneersAllocatedRaw.toString(),
        pioneersDustRaw: pioneerSimulation.pioneersDustRaw.toString(),
        pioneersLostWhileSupplyZeroRaw: pioneerSimulation.lostWhileSupplyZeroRaw.toString(),
        takadaoShareRaw: takadaoShareRaw.toString(),
        takadaoAllocatedRaw: takadaoAllocatedRaw.toString(),
        takadaoDustRaw: takadaoDustRaw.toString(),
        totalModuleDustRaw: totalModuleDustRaw.toString(),
        checkpointsCount: pioneerSimulation.checkpointsCount,
        testMode: cli.testMode,
        revenueReceiverSource: cli.testMode ? "env.TESTNET_DEPLOYER_ADDRESS" : "AddressManager",
        revenueReceiver,
        allocations,
    }

    console.log("")
    logSection("Write Output")
    fs.mkdirSync(path.dirname(outputPaths.allocationsJson), { recursive: true })
    fs.writeFileSync(outputPaths.allocationsJson, JSON.stringify(outputJson, null, 2), "utf8")
    console.log(`JSON written to: ${outputPaths.allocationsJson}`)

    const csvLines = ["address,amountRaw"]
    for (const allocation of allocations) {
        csvLines.push(`${allocation.address},${allocation.amountRaw}`)
    }

    fs.writeFileSync(outputPaths.allocationsCsv, csvLines.join("\n"), "utf8")
    console.log(`CSV written to:  ${outputPaths.allocationsCsv}`)

    console.log("")
    console.log("Done building backfill allocations.")
}

main().catch((err) => {
    console.error("Error while building backfill allocations:")
    console.error(err)
    process.exit(1)
})
