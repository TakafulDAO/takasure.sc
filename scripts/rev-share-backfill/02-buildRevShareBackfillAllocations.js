require("dotenv").config()
const { ethers } = require("ethers")
const fs = require("fs")
const path = require("path")

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

const PIONEERS_FILE = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/pioneers/revshare_pioneers.json",
)

const OUT_JSON = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.json",
)
const OUT_CSV = path.join(
    process.cwd(),
    "scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.csv",
)

const ARBITRUM_ONE_CHAIN_ID = 42161
const ARBITRUM_SEPOLIA_CHAIN_ID = 421614
const WAD = 10n ** 18n

// USDC decimals
const TOKEN_DECIMALS = 6

// Todo: Change this to the real amount
const TOTAL_BACKFILL_TOKENS = "100000" // in human units, "100000" means 100,000 USDC

// Pioneers' share in basis points (75% = 7500 bps)
const PIONEERS_SHARE_BPS = 7500n
const BPS_DENOMINATOR = 10000n

// Historical revenue window to simulate with the same math as RevShareModule.
// BACKFILL_START_TS is the revenue accrual start date.
// BACKFILL_END_TS should be the RevShareModule deployment date.
const BACKFILL_START_TS = Math.floor(new Date("2025-06-01T00:00:00Z").getTime() / 1000)
const BACKFILL_END_TS = Math.floor(new Date("2025-12-01T00:00:00Z").getTime() / 1000)

const ADMIN_REVENUE_RECEIVER_KEY = "ADMIN__REVENUE_RECEIVER"

function printHelp() {
    console.log(`RevShare backfill allocation builder

Builds the RevShare backfill allocation output using the same accumulator model as RevShareModule.

Input file:
- scripts/rev-share-backfill/output/pioneers/revshare_pioneers.json

Output files:
- scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.json
- scripts/rev-share-backfill/output/allocations/revshare_backfill_allocations.csv

Revenue receiver behavior:
- Default: resolve ADMIN__REVENUE_RECEIVER from AddressManager
- Test mode: use TESTNET_DEPLOYER_ADDRESS from .env instead

Flags:
- --test [true|false]  Use TESTNET_DEPLOYER_ADDRESS for the Takadao allocation row. If the value is omitted, true is assumed.
- --help               Show this help message

Examples:
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --test
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --test false
`)
}

function parseBooleanFlagValue(flagName, value) {
    if (value === "true") return true
    if (value === "false") return false

    throw new Error(`Invalid value for ${flagName}: ${value}. Expected true or false.`)
}

function parseArgs(argv) {
    const parsed = {
        showHelp: false,
        testMode: false,
    }

    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i]

        if (arg === "--help") {
            parsed.showHelp = true
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

function buildSimulationInputs(pioneers) {
    const tokenSnapshots = []
    const accountStates = new Map()
    const supplyDeltaByTs = new Map()
    const balanceIncreaseByTs = new Map()
    const checkpoints = new Set([BACKFILL_START_TS, BACKFILL_END_TS])

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

            if (mintedAt <= BACKFILL_START_TS) {
                // Token already existed at stream start.
            } else if (mintedAt < BACKFILL_END_TS) {
                supplyDeltaByTs.set(mintedAt, (supplyDeltaByTs.get(mintedAt) || 0n) + 1n)
                checkpoints.add(mintedAt)
            }

            if (holdingSince <= BACKFILL_START_TS) {
                accountState.balance += 1n
            } else if (holdingSince < BACKFILL_END_TS) {
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
        if (token.mintedAt <= BACKFILL_START_TS) {
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

function simulatePioneerAccrual(pioneersBackfillRaw, pioneers) {
    if (!(BACKFILL_START_TS < BACKFILL_END_TS)) {
        throw new Error("Time config invalid: require BACKFILL_START_TS < BACKFILL_END_TS")
    }

    const {
        accountStates,
        supplyDeltaByTs,
        balanceIncreaseByTs,
        checkpoints,
        initialSupply,
        tokenSnapshots,
    } = buildSimulationInputs(pioneers)

    const rewardsDuration = BigInt(BACKFILL_END_TS - BACKFILL_START_TS)
    const rewardRatePioneersScaled = (pioneersBackfillRaw * WAD) / rewardsDuration

    let currentSupply = initialSupply
    let currentAccumulatorScaled = 0n
    let lostWhileSupplyZeroRaw = 0n

    console.log(`Simulation checkpoints: ${checkpoints.length}`)
    console.log(`Initial totalSupply at BACKFILL_START_TS: ${currentSupply.toString()}`)
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

    return {
        allocations,
        rewardsDuration,
        rewardRatePioneersScaled,
        pioneersAllocatedRaw,
        pioneersDustRaw,
        lostWhileSupplyZeroRaw,
        totalNfts: BigInt(tokenSnapshots.length),
        checkpointsCount: checkpoints.length,
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

    console.log("=== Build RevShare backfill allocations (RevShareModule math) ===")

    if (!fs.existsSync(PIONEERS_FILE)) {
        throw new Error(`Pioneers file not found at ${PIONEERS_FILE}. Run 01-exportRevSharePioneers first.`)
    }

    const pioneersJson = JSON.parse(fs.readFileSync(PIONEERS_FILE, "utf8"))
    const pioneers = pioneersJson.pioneers || []

    if (pioneers.length === 0) {
        throw new Error("No pioneers found in revshare_pioneers.json")
    }

    const chainId = Number(pioneersJson.chainId)
    if (!Number.isInteger(chainId)) {
        throw new Error("Pioneers file is missing a valid chainId")
    }

    const chainCfg = chainConfigFromChainId(chainId)
    console.log(`Loaded ${pioneers.length} pioneers from ${PIONEERS_FILE}`)
    console.log(`Using chainId ${chainId} (${chainCfg.network})`)
    console.log(`Test mode: ${cli.testMode ? "enabled" : "disabled"}`)

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

    const pioneerSimulation = simulatePioneerAccrual(pioneersBackfillRaw, pioneers)
    const rewardRateTakadaoScaled = (takadaoShareRaw * WAD) / pioneerSimulation.rewardsDuration
    const takadaoAllocatedRaw =
        (pioneerSimulation.rewardsDuration * rewardRateTakadaoScaled) / WAD
    const takadaoDustRaw = takadaoShareRaw - takadaoAllocatedRaw

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

    const allocations = [...pioneerSimulation.allocations]
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
        backfillStartTs: BACKFILL_START_TS,
        backfillEndTs: BACKFILL_END_TS,
        rewardsDurationSec: pioneerSimulation.rewardsDuration.toString(),
        totalNfts: pioneerSimulation.totalNfts.toString(),
        pioneersCount: pioneers.length,
        calculationModel:
            "single notifyNewRevenue at BACKFILL_START_TS, claim at BACKFILL_END_TS, with pioneers accrued using RevShareModule per-NFT accumulator checkpoints",
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

    fs.mkdirSync(path.dirname(OUT_JSON), { recursive: true })
    fs.writeFileSync(OUT_JSON, JSON.stringify(outputJson, null, 2), "utf8")
    console.log(`JSON written to: ${OUT_JSON}`)

    const csvLines = ["address,amountRaw"]
    for (const allocation of allocations) {
        csvLines.push(`${allocation.address},${allocation.amountRaw}`)
    }

    fs.writeFileSync(OUT_CSV, csvLines.join("\n"), "utf8")
    console.log(`CSV written to:  ${OUT_CSV}`)

    console.log("Done building backfill allocations.")
}

main().catch((err) => {
    console.error("Error while building backfill allocations:")
    console.error(err)
    process.exit(1)
})
