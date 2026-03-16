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

// Historical backfill is pioneers-only because Takadao is already settled off-module.
const BACKFILL_MODE = "pioneers-only"
const PIONEERS_BACKFILL_TOKENS = "4873.628213" // workbook 1. Revenue!B73 in human units

const ADMIN_REVENUE_RECEIVER_KEY = "ADMIN__REVENUE_RECEIVER"

function printHelp() {
    console.log(`RevShare backfill allocation builder

Builds the pioneers-only RevShare backfill allocation output using the same
per-NFT accumulator model as RevShareModule's pioneers stream.

Input file:
- default: the pioneer export from the same --chain
- optional override: --pioneers-chain <arb-one|arb-sep>
- arb-one -> scripts/rev-share-backfill/output/mainnet/pioneers/revshare_pioneers.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/pioneers/revshare_pioneers.json

Output files:
- arb-one -> scripts/rev-share-backfill/output/mainnet/allocations/revshare_backfill_allocations.json
- arb-one -> scripts/rev-share-backfill/output/mainnet/allocations/revshare_backfill_allocations.csv
- arb-sep -> scripts/rev-share-backfill/output/testnet/allocations/revshare_backfill_allocations.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/allocations/revshare_backfill_allocations.csv

Backfill mode:
- Fixed: ${BACKFILL_MODE}
- Takadao is assumed to be already settled off-module
- No Takadao allocation row is emitted by this script

Excluded pioneer behavior:
- Default: resolve ADMIN__REVENUE_RECEIVER from AddressManager
- Test mode: use TESTNET_DEPLOYER_ADDRESS from .env instead
- If that address currently holds NFTs, it is excluded from pioneer accrual to mirror RevShareModule's pioneers stream

Backfill window:
- Start: earliest token mintedAt found in the pioneer export JSON
- End: current time when the script runs

Flags:
- --chain <arb-one|arb-sep>  Select the input/output directory set
- --pioneers-chain <arb-one|arb-sep>  Override the pioneer snapshot source while keeping outputs on --chain
- --test [true|false]  Use TESTNET_DEPLOYER_ADDRESS as the excluded pioneer address. If the value is omitted, true is assumed.
- --help               Show this help message

Examples:
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-one
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-sep --test
- node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-sep --pioneers-chain arb-one --test
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
        pioneersChainId: null,
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

        if (arg === "--pioneers-chain") {
            const value = argv[i + 1]
            if (!value) {
                throw new Error("Missing value for --pioneers-chain. Expected arb-one or arb-sep.")
            }

            const pioneersChainId = CHAIN_FLAG_TO_ID[value]
            if (!pioneersChainId) {
                throw new Error(
                    `Invalid --pioneers-chain value: ${value}. Expected arb-one or arb-sep.`,
                )
            }

            parsed.pioneersChainId = pioneersChainId
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

function buildOutputPaths(chainId, pioneersChainId = chainId) {
    const outputRoot = path.join(
        process.cwd(),
        "scripts/rev-share-backfill/output",
        outputScopeName(chainId),
    )
    const pioneersOutputRoot = path.join(
        process.cwd(),
        "scripts/rev-share-backfill/output",
        outputScopeName(pioneersChainId),
    )

    return {
        outputRoot,
        pioneersOutputRoot,
        pioneersJson: path.join(pioneersOutputRoot, "pioneers", "revshare_pioneers.json"),
        allocationsJson: path.join(outputRoot, "allocations", "revshare_backfill_allocations.json"),
        allocationsCsv: path.join(outputRoot, "allocations", "revshare_backfill_allocations.csv"),
    }
}

function resolveChainId(cliChainId) {
    if (cliChainId === null) {
        throw new Error(
            "Missing required --chain flag. Expected --chain arb-one or --chain arb-sep.",
        )
    }

    return cliChainId
}

function resolvePioneersChainId(cliPioneersChainId, executionChainId) {
    return cliPioneersChainId === null ? executionChainId : cliPioneersChainId
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
        `Unsupported chainId ${chainId}. Expected ${ARBITRUM_ONE_CHAIN_ID} or ${ARBITRUM_SEPOLIA_CHAIN_ID}.`,
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
                throw new Error(
                    `Invalid mintedAt while deriving backfill window for token ${token.tokenId}`,
                )
            }

            if (oldestMintedAt === null || mintedAt < oldestMintedAt) {
                oldestMintedAt = mintedAt
            }
        }
    }

    if (oldestMintedAt === null) {
        throw new Error(
            "Unable to derive backfillStartTs from pioneer export. No token mintedAt values found.",
        )
    }

    // Backfill starts when the oldest currently-held token first entered supply and ends at execution time.
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

    // Mirror RevShareModule's lazy accounting: settle pending revenue before mutating balance checkpoints.
    if (accountState.balance > 0n && deltaScaled > 0n) {
        accountState.revenueRaw += (accountState.balance * deltaScaled) / WAD
    }

    accountState.paidAccumulatorScaled = currentAccumulatorScaled
}

function buildSimulationInputs(pioneers, backfillStartTs, backfillEndTs, excludedPioneerAddress) {
    // Turn token-level snapshots into the same inputs the module cares about: supply changes and balance changes over time.
    const tokenSnapshots = []
    const accountStates = new Map()
    const supplyDeltaByTs = new Map()
    const balanceIncreaseByTs = new Map()
    const checkpoints = new Set([backfillStartTs, backfillEndTs])
    let excludedPioneerNfts = 0n

    for (const pioneer of pioneers) {
        const address = normalizeAddress(pioneer.address)
        const isExcludedPioneer = excludedPioneerAddress && address === excludedPioneerAddress
        const tokens = Array.isArray(pioneer.tokens) ? pioneer.tokens : null

        if (!tokens || tokens.length === 0) {
            throw new Error(
                `Pioneer ${address} is missing token snapshots. Re-run 01-exportRevSharePioneers.js before script 02.`,
            )
        }

        if (tokens.length !== Number(BigInt(pioneer.nftBalance))) {
            throw new Error(
                `Token snapshot count mismatch for ${address}. nftBalance=${pioneer.nftBalance} tokens=${tokens.length}`,
            )
        }

        let accountState = null
        if (!isExcludedPioneer) {
            accountState = accountStates.get(address)
            if (!accountState) {
                accountState = {
                    balance: 0n,
                    revenueRaw: 0n,
                    paidAccumulatorScaled: 0n,
                }
                accountStates.set(address, accountState)
            }
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
                    `Invalid token timing for token ${tokenId}: mintedAt ${mintedAt} > holdingSince ${holdingSince}`,
                )
            }

            tokenSnapshots.push({
                owner: address,
                tokenId,
                mintedAt,
                holdingSince,
            })

            if (isExcludedPioneer) {
                excludedPioneerNfts += 1n
            }

            if (mintedAt <= backfillStartTs) {
                // Token already existed at stream start.
            } else if (mintedAt < backfillEndTs) {
                // mintedAt changes totalSupply, even if the final holder did not own the token yet.
                supplyDeltaByTs.set(mintedAt, (supplyDeltaByTs.get(mintedAt) || 0n) + 1n)
                checkpoints.add(mintedAt)
            }

            if (holdingSince <= backfillStartTs) {
                if (accountState) {
                    accountState.balance += 1n
                }
            } else if (holdingSince < backfillEndTs) {
                // holdingSince changes the account balance used for settlement from that timestamp onward.
                if (accountState) {
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
        excludedPioneerNfts,
    }
}

function simulatePioneerAccrual(
    pioneersBackfillRaw,
    pioneers,
    backfillStartTs,
    backfillEndTs,
    excludedPioneerAddress,
) {
    if (!(backfillStartTs < backfillEndTs)) {
        throw new Error("Time config invalid: require backfillStartTs < backfillEndTs")
    }

    // Replay one synthetic RevShareModule stream across every timestamp where supply or balances can change.
    const {
        accountStates,
        supplyDeltaByTs,
        balanceIncreaseByTs,
        checkpoints,
        initialSupply,
        tokenSnapshots,
        excludedPioneerNfts,
    } = buildSimulationInputs(pioneers, backfillStartTs, backfillEndTs, excludedPioneerAddress)

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
                // This matches the module: pioneer-side revenue emitted while supply is zero is lost as dust.
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

    const pioneerRevenueStats = Array.from(accountStates.entries()).map(
        ([address, accountState]) => ({
            address,
            amountRaw: accountState.revenueRaw,
        }),
    )

    let highestRevenuePioneer = null
    let lowestRevenuePioneer = null

    for (const pioneerRevenueStat of pioneerRevenueStats) {
        if (
            !highestRevenuePioneer ||
            pioneerRevenueStat.amountRaw > highestRevenuePioneer.amountRaw
        ) {
            highestRevenuePioneer = pioneerRevenueStat
        }

        if (
            !lowestRevenuePioneer ||
            pioneerRevenueStat.amountRaw < lowestRevenuePioneer.amountRaw
        ) {
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
        pioneerRevenueStats.length > 0
            ? pioneersAllocatedRaw / BigInt(pioneerRevenueStats.length)
            : 0n

    return {
        allocations,
        rewardsDuration,
        rewardRatePioneersScaled,
        pioneersAllocatedRaw,
        pioneersDustRaw,
        lostWhileSupplyZeroRaw,
        totalNfts: BigInt(tokenSnapshots.length),
        excludedPioneerNfts,
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

async function resolveExcludedPioneerAddress(chainId, testMode) {
    if (testMode) {
        const testRevenueReceiver = process.env.TESTNET_DEPLOYER_ADDRESS || ""

        if (!testRevenueReceiver) {
            throw new Error(
                "TESTNET_DEPLOYER_ADDRESS is required when --test is enabled. Set it in .env and rerun.",
            )
        }

        if (!ethers.utils.isAddress(testRevenueReceiver)) {
            throw new Error(
                "TESTNET_DEPLOYER_ADDRESS is not a valid address. Fix it in .env and rerun.",
            )
        }

        console.log(
            `Using TESTNET_DEPLOYER_ADDRESS for --test mode as the excluded pioneer address: ${testRevenueReceiver}`,
        )
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
        throw new Error(
            "ADDRESS_MANAGER_ADDRESS is missing or invalid. Set it correctly and rerun the script.",
        )
    }

    console.log(`Connecting to AddressManager at ${addressManagerAddress}`)
    const provider = new ethers.providers.JsonRpcProvider(chainCfg.rpcUrl)
    const addressManager = new ethers.Contract(
        addressManagerAddress,
        addressManagerDeployment.abi,
        provider,
    )

    try {
        const protocolAddress = await addressManager.getProtocolAddressByName(
            ADMIN_REVENUE_RECEIVER_KEY,
        )
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
    const pioneersSourceChainId = resolvePioneersChainId(cli.pioneersChainId, chainId)
    const outputPaths = buildOutputPaths(chainId, pioneersSourceChainId)

    console.log("=== Build RevShare pioneers-only backfill allocations ===")
    console.log("")
    logSection("Configuration")
    console.log(`Using execution/output scope: ${outputScopeName(chainId)} (${chainName(chainId)})`)
    console.log(
        `Using pioneers source scope: ${outputScopeName(pioneersSourceChainId)} (${chainName(pioneersSourceChainId)})`,
    )
    console.log(`Backfill mode: ${BACKFILL_MODE}`)
    console.log(`Configured pioneers backfill: ${PIONEERS_BACKFILL_TOKENS} USDC`)

    if (!fs.existsSync(outputPaths.pioneersJson)) {
        throw new Error(
            `Pioneers file not found at ${outputPaths.pioneersJson}. Run 01-exportRevSharePioneers.js with --chain ${pioneersSourceChainId === ARBITRUM_ONE_CHAIN_ID ? "arb-one" : "arb-sep"} first.`,
        )
    }

    const pioneersJson = JSON.parse(fs.readFileSync(outputPaths.pioneersJson, "utf8"))
    const pioneers = pioneersJson.pioneers || []

    if (pioneers.length === 0) {
        throw new Error("No pioneers found in revshare_pioneers.json")
    }

    const pioneersSnapshotChainId = Number(pioneersJson.chainId)
    if (!Number.isInteger(pioneersSnapshotChainId)) {
        throw new Error("Pioneers file is missing a valid chainId")
    }
    if (pioneersSnapshotChainId !== pioneersSourceChainId) {
        throw new Error(
            `Pioneers file chainId ${pioneersSnapshotChainId} does not match --pioneers-chain ${pioneersSourceChainId}. Use the matching pioneer export.`,
        )
    }

    const chainCfg = chainConfigFromChainId(chainId)
    console.log(`Loaded ${pioneers.length} pioneers from ${outputPaths.pioneersJson}`)
    console.log(`Execution chainId ${chainId} (${chainCfg.network})`)
    console.log(`Pioneers source chainId ${pioneersSourceChainId} (${chainName(pioneersSourceChainId)})`)
    console.log(`Test mode: ${cli.testMode ? "enabled" : "disabled"}`)
    console.log("")

    logSection("Excluded Pioneer Address")
    const excludedPioneerAddress = await resolveExcludedPioneerAddress(chainId, cli.testMode)
    console.log(
        `ADMIN__REVENUE_RECEIVER resolved to: ${excludedPioneerAddress} (used only for pioneer exclusion)`,
    )

    const excludedPioneer = pioneers.find(
        (pioneer) => normalizeAddress(pioneer.address) === excludedPioneerAddress,
    )
    if (excludedPioneer) {
        console.log(
            `Excluded pioneer address currently holds ${excludedPioneer.nftBalance} NFT(s) and will be excluded from pioneer accrual to mirror RevShareModule behavior.`,
        )
    }
    console.log("")

    logSection("Backfill Window")
    const { backfillStartTs, backfillEndTs } = deriveBackfillWindow(pioneers)
    console.log(
        `Derived backfillStartTs: ${backfillStartTs} (${formatUnixTimestamp(backfillStartTs)})`,
    )
    console.log(`Derived backfillEndTs:   ${backfillEndTs} (${formatUnixTimestamp(backfillEndTs)})`)
    console.log("")

    logSection("Backfill Amount")
    const pioneersBackfillRaw = parseAmountToRaw(PIONEERS_BACKFILL_TOKENS, TOKEN_DECIMALS)
    console.log(
        `PIONEERS_BACKFILL: ${PIONEERS_BACKFILL_TOKENS} tokens = ${pioneersBackfillRaw.toString()} raw`,
    )
    console.log("")

    const pioneerSimulation = simulatePioneerAccrual(
        pioneersBackfillRaw,
        pioneers,
        backfillStartTs,
        backfillEndTs,
        excludedPioneerAddress,
    )

    logSection("Allocation Totals")
    console.log(
        `Pioneers allocated raw: ${pioneerSimulation.pioneersAllocatedRaw.toString()} (~${formatRaw(
            pioneerSimulation.pioneersAllocatedRaw,
            TOKEN_DECIMALS,
        )} tokens)`,
    )
    console.log(
        `Pioneers dust raw:      ${pioneerSimulation.pioneersDustRaw.toString()} (~${formatRaw(
            pioneerSimulation.pioneersDustRaw,
            TOKEN_DECIMALS,
        )} tokens)`,
    )
    console.log("")

    logSection("Pioneer Revenue Stats")
    if (pioneerSimulation.highestRevenuePioneer) {
        console.log(
            `Highest revenue pioneer: ${pioneerSimulation.highestRevenuePioneer.address} (${formatRaw(
                BigInt(pioneerSimulation.highestRevenuePioneer.amountRaw),
                TOKEN_DECIMALS,
            )} USDC)`,
        )
    }
    if (pioneerSimulation.lowestRevenuePioneer) {
        console.log(
            `Lowest revenue pioneer:  ${pioneerSimulation.lowestRevenuePioneer.address} (${formatRaw(
                BigInt(pioneerSimulation.lowestRevenuePioneer.amountRaw),
                TOKEN_DECIMALS,
            )} USDC)`,
        )
    }
    console.log(
        `Average pioneer revenue: ${formatRaw(
            BigInt(pioneerSimulation.averagePioneerRevenueRaw),
            TOKEN_DECIMALS,
        )} USDC across ${pioneerSimulation.pioneersWithBalanceCount} pioneers`,
    )
    console.log("")

    const allocations = [...pioneerSimulation.allocations].sort((a, b) =>
        a.address.localeCompare(b.address),
    )

    let sumAllAlloc = 0n
    for (const allocation of allocations) {
        sumAllAlloc += BigInt(allocation.amountRaw)
    }

    const totalModuleDustRaw = pioneersBackfillRaw - pioneerSimulation.pioneersAllocatedRaw

    console.log("")
    logSection("Final Totals")
    console.log(
        `Sum of pioneer allocations: ${sumAllAlloc.toString()} raw (~${formatRaw(sumAllAlloc, TOKEN_DECIMALS)} tokens)`,
    )
    console.log(
        `Total pioneers-only dust: ${totalModuleDustRaw.toString()} raw (~${formatRaw(
            totalModuleDustRaw,
            TOKEN_DECIMALS,
        )} tokens)`,
    )

    const outputJson = {
        chainId,
        network: chainCfg.network,
        pioneersSourceChainId,
        pioneersSourceNetwork: chainName(pioneersSourceChainId),
        pioneersSourceFile: outputPaths.pioneersJson,
        snapshotBlock: pioneersJson.snapshotBlock ?? null,
        tokenDecimals: TOKEN_DECIMALS,
        backfillMode: BACKFILL_MODE,
        pioneersBackfillTokens: PIONEERS_BACKFILL_TOKENS,
        totalBackfillTokens: PIONEERS_BACKFILL_TOKENS,
        totalBackfillRaw: pioneersBackfillRaw.toString(),
        backfillStartTs,
        backfillEndTs,
        backfillStartSource: "minimum token.mintedAt from pioneer export",
        backfillEndSource: "current system time at script execution",
        rewardsDurationSec: pioneerSimulation.rewardsDuration.toString(),
        totalNfts: pioneerSimulation.totalNfts.toString(),
        excludedPioneerNfts: pioneerSimulation.excludedPioneerNfts.toString(),
        pioneersCount: pioneers.length,
        calculationModel:
            "pioneers-only historical backfill using RevShareModule per-NFT accumulator checkpoints; Takadao assumed already settled off-module",
        rewardRatePioneersScaled: pioneerSimulation.rewardRatePioneersScaled.toString(),
        pioneersBackfillRaw: pioneersBackfillRaw.toString(),
        pioneersAllocatedRaw: pioneerSimulation.pioneersAllocatedRaw.toString(),
        pioneersDustRaw: pioneerSimulation.pioneersDustRaw.toString(),
        pioneersLostWhileSupplyZeroRaw: pioneerSimulation.lostWhileSupplyZeroRaw.toString(),
        totalModuleDustRaw: totalModuleDustRaw.toString(),
        checkpointsCount: pioneerSimulation.checkpointsCount,
        testMode: cli.testMode,
        excludedPioneerAddressSource: cli.testMode ? "env.TESTNET_DEPLOYER_ADDRESS" : "AddressManager",
        excludedPioneerAddress,
        revenueReceiverSource: cli.testMode ? "env.TESTNET_DEPLOYER_ADDRESS" : "AddressManager",
        revenueReceiver: excludedPioneerAddress,
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
