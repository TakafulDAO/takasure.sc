require("dotenv").config()
const { ethers } = require("ethers")
const fs = require("fs")
const path = require("path")
const {
    SAFE_ADDRESS,
    getNextSafeNonce,
    sendTransactionsToSafe,
} = require("../save-funds/automation/safeSubmit")
const { sendOnchain } = require("../save-funds/automation/sendOnchain")

/*//////////////////////////////////////////////////////////////
                                 CONFIG
//////////////////////////////////////////////////////////////*/

const ARBITRUM_ONE_CHAIN_ID = 42161
const ARBITRUM_SEPOLIA_CHAIN_ID = 421614
const CHAIN_FLAG_TO_ID = {
    "arb-one": ARBITRUM_ONE_CHAIN_ID,
    "arb-sep": ARBITRUM_SEPOLIA_CHAIN_ID,
}

// Batch size for adminBackfillRevenue
const BATCH_SIZE = parseInt(process.env.BACKFILL_BATCH_SIZE || "20", 10)

/*//////////////////////////////////////////////////////////////
                               HELPERS
//////////////////////////////////////////////////////////////*/

function printHelp() {
    console.log(`RevShare backfill batch runner

Consumes the allocations from script 02 and then:
- arb-one: creates one Safe proposal per adminBackfillRevenue batch using sequential Safe nonces
- arb-sep: sends the adminBackfillRevenue batches onchain using TESTNET_PK
- --dry-run: builds the exact same batches and report without creating proposals or sending txs

Input file:
- arb-one -> scripts/rev-share-backfill/output/mainnet/allocations/revshare_backfill_allocations.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/allocations/revshare_backfill_allocations.json

Output report:
- arb-one -> scripts/rev-share-backfill/output/mainnet/execution/revshare_backfill_execution_report.json
- arb-sep -> scripts/rev-share-backfill/output/testnet/execution/revshare_backfill_execution_report.json

Environment requirements:
- arb-one: SAFE_PROPOSER_PK and ARBITRUM_MAINNET_RPC_URL
- arb-sep: ARBITRUM_TESTNET_SEPOLIA_RPC_URL, TESTNET_PK, TESTNET_DEPLOYER_ADDRESS
- --dry-run: does not require Safe submission or testnet executor credentials
- optional: BACKFILL_BATCH_SIZE to control addresses per adminBackfillRevenue call (default 20)

Flags:
- --chain <arb-one|arb-sep>  Select the input/output directory set and action mode
- --dry-run                  Build the same batches and report, but do not send anything
- --help                     Show this help message

Examples:
- node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-one
- node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-sep
- node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-one --dry-run
`)
}

function parseArgs(argv) {
    const parsed = {
        chainId: null,
        dryRun: false,
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

        if (arg === "--dry-run") {
            parsed.dryRun = true
            continue
        }

        throw new Error(
            `Unknown argument: ${arg}. Expected --chain arb-one or --chain arb-sep, with optional --dry-run.`,
        )
    }

    if (!parsed.showHelp && parsed.chainId === null) {
        throw new Error("Missing required --chain flag. Expected --chain arb-one or --chain arb-sep.")
    }

    return parsed
}

function chainConfigFromChainId(chainId) {
    if (chainId === ARBITRUM_ONE_CHAIN_ID) {
        return {
            network: "arbitrum-one",
            deploymentsDir: "mainnet_arbitrum_one",
            outputScope: "mainnet",
            automationChainName: "arb-one",
            actionMode: "safe-proposal",
            rpcUrl: process.env.ARBITRUM_MAINNET_RPC_URL || "",
        }
    }

    if (chainId === ARBITRUM_SEPOLIA_CHAIN_ID) {
        return {
            network: "arbitrum-sepolia",
            deploymentsDir: "testnet_arbitrum_sepolia",
            outputScope: "testnet",
            automationChainName: "arb-sepolia",
            actionMode: "send-onchain",
            rpcUrl: process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL || "",
        }
    }

    throw new Error(
        `Unsupported chainId ${chainId}. Expected ${ARBITRUM_ONE_CHAIN_ID} or ${ARBITRUM_SEPOLIA_CHAIN_ID}.`,
    )
}

function buildOutputPaths(chainId) {
    const chainCfg = chainConfigFromChainId(chainId)
    const outputRoot = path.join(
        process.cwd(),
        "scripts/rev-share-backfill/output",
        chainCfg.outputScope,
    )

    return {
        allocationsJson: path.join(outputRoot, "allocations", "revshare_backfill_allocations.json"),
        reportJson: path.join(
            outputRoot,
            "execution",
            "revshare_backfill_execution_report.json",
        ),
    }
}

function loadRevShareModuleDeployment(chainId) {
    const chainCfg = chainConfigFromChainId(chainId)
    const deploymentPath = path.join(
        process.cwd(),
        "deployments",
        chainCfg.deploymentsDir,
        "RevShareModule.json",
    )

    if (!fs.existsSync(deploymentPath)) {
        throw new Error(`RevShareModule deployment not found at ${deploymentPath}`)
    }

    return JSON.parse(fs.readFileSync(deploymentPath, "utf8"))
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
    return ethers.utils.getAddress(String(address))
}

function logSection(title) {
    console.log(`\n=== ${title} ===`)
}

function writeReport(reportPath, report) {
    fs.mkdirSync(path.dirname(reportPath), { recursive: true })
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2), "utf8")
}

async function resolveRevShareModuleAddress(chainCfg, deployment) {
    const deploymentAddress = normalizeAddress(deployment.address)
    const overrideAddress =
        process.env.REVSHARE_MODULE_ADDRESS && process.env.REVSHARE_MODULE_ADDRESS !== "0x"
            ? normalizeAddress(process.env.REVSHARE_MODULE_ADDRESS)
            : null
    const resolvedAddress = overrideAddress || deploymentAddress

    if (!chainCfg.rpcUrl) {
        throw new Error(
            `RPC URL for ${chainCfg.network} is required to validate the RevShareModule address.`,
        )
    }

    const provider = new ethers.providers.JsonRpcProvider(chainCfg.rpcUrl)
    const code = await provider.getCode(resolvedAddress)
    if (!code || code === "0x") {
        throw new Error(
            `RevShareModule address ${resolvedAddress} has no code on ${chainCfg.network}. Check the selected chain and deployment address before retrying.`,
        )
    }

    return {
        address: resolvedAddress,
        source: overrideAddress ? "env.REVSHARE_MODULE_ADDRESS" : "deployment",
        deploymentAddress,
    }
}

function buildBatches({ allocations, batchSize, tokenDecimals, moduleAddress, moduleAbi }) {
    const iface = new ethers.utils.Interface(moduleAbi)
    const batches = []

    for (let i = 0; i < allocations.length; i += batchSize) {
        const slice = allocations.slice(i, i + batchSize)
        const batchIndex = Math.floor(i / batchSize)
        const accounts = slice.map((allocation) => normalizeAddress(allocation.address))
        const amounts = slice.map((allocation) => allocation.amountRaw)

        if (accounts.length === 0) continue
        if (accounts.length !== amounts.length) {
            throw new Error(`accounts.length !== amounts.length in batch ${batchIndex}`)
        }

        let sumRaw = 0n
        for (const allocation of slice) {
            sumRaw += BigInt(allocation.amountRaw)
        }

        // Each batch becomes its own adminBackfillRevenue call so execution stays bounded.
        const calldata = iface.encodeFunctionData("adminBackfillRevenue", [accounts, amounts])

        batches.push({
            batchIndex,
            to: normalizeAddress(moduleAddress),
            value: "0",
            numAddresses: accounts.length,
            sumRaw: sumRaw.toString(),
            sumTokens: formatRaw(sumRaw, tokenDecimals),
            accounts,
            amounts,
            calldata,
        })
    }

    return batches
}

async function proposeToSafe(batches, rpcUrl, onProgress) {
    // Use the next available Safe nonce as the base and pin one proposal per batch to avoid replacement.
    const baseNonce = await getNextSafeNonce()
    const proposals = []
    let safeAddress = null
    let proposerAddress = null
    let txServiceUrl = null

    for (const batch of batches) {
        const result = await sendTransactionsToSafe({
            transactions: [
                {
                    to: batch.to,
                    data: batch.calldata,
                    value: batch.value,
                },
            ],
            nonce: baseNonce + batch.batchIndex,
            rpcUrl,
        })

        safeAddress = result.safeAddress
        proposerAddress = result.senderAddress
        txServiceUrl = result.txServiceUrl

        proposals.push({
            batchIndex: batch.batchIndex,
            safeTxHash: result.safeTxHash,
            nonce: result.nonce,
            to: batch.to,
            numAddresses: batch.numAddresses,
            sumRaw: batch.sumRaw,
            sumTokens: batch.sumTokens,
        })

        if (onProgress) {
            onProgress({
                mode: "safe-proposal",
                baseNonce,
                safeAddress,
                proposerAddress,
                txServiceUrl,
                proposal: proposals[proposals.length - 1],
            })
        }
    }

    return {
        mode: "safe-proposal",
        baseNonce,
        safeAddress: safeAddress || normalizeAddress(SAFE_ADDRESS),
        proposerAddress,
        txServiceUrl,
        proposals,
    }
}

function resolveSepoliaExecutor() {
    const expectedExecutor = process.env.TESTNET_DEPLOYER_ADDRESS || ""
    if (!expectedExecutor) {
        throw new Error("TESTNET_DEPLOYER_ADDRESS is required for --chain arb-sep")
    }

    const normalizedExpectedExecutor = normalizeAddress(expectedExecutor)
    const pkRaw = process.env.TESTNET_PK || ""
    if (!pkRaw) {
        throw new Error("TESTNET_PK is required for --chain arb-sep")
    }

    const normalizedPk = pkRaw.startsWith("0x") ? pkRaw : `0x${pkRaw}`
    const actualExecutor = normalizeAddress(new ethers.Wallet(normalizedPk).address)
    if (actualExecutor !== normalizedExpectedExecutor) {
        throw new Error(
            `TESTNET_PK signer mismatch. Expected TESTNET_DEPLOYER_ADDRESS ${normalizedExpectedExecutor}, got ${actualExecutor}.`,
        )
    }

    return normalizedExpectedExecutor
}

async function executeOnSepolia(batches, chainCfg, onProgress) {
    // Testnet skips Safe and executes each batch directly from the operator wallet.
    const normalizedExpectedExecutor = resolveSepoliaExecutor()
    const receipts = []

    for (const batch of batches) {
        const receipt = await sendOnchain({
            to: batch.to,
            data: batch.calldata,
            value: batch.value,
            chainCfg: { name: chainCfg.automationChainName },
        })

        receipts.push({
            batchIndex: batch.batchIndex,
            txHash: receipt.hash,
            from: normalizeAddress(receipt.from),
            to: normalizeAddress(receipt.to),
            nonce: receipt.nonce,
            blockNumber: receipt.blockNumber,
            gasUsed: receipt.gasUsed,
            numAddresses: batch.numAddresses,
            sumRaw: batch.sumRaw,
            sumTokens: batch.sumTokens,
        })

        if (onProgress) {
            onProgress({
                mode: "send-onchain",
                executorAddress: normalizedExpectedExecutor,
                receipt: receipts[receipts.length - 1],
            })
        }
    }

    return {
        mode: "send-onchain",
        executorAddress: normalizedExpectedExecutor,
        receipts,
    }
}

function buildDryRunResult(batches, chainCfg) {
    if (chainCfg.actionMode === "safe-proposal") {
        return {
            mode: "dry-run",
            targetActionMode: chainCfg.actionMode,
            safeAddress: normalizeAddress(SAFE_ADDRESS),
            proposerAddress: null,
            txServiceUrl: null,
            proposals: batches.map((batch) => ({
                batchIndex: batch.batchIndex,
                safeTxHash: null,
                nonce: null,
                to: batch.to,
                numAddresses: batch.numAddresses,
                sumRaw: batch.sumRaw,
                sumTokens: batch.sumTokens,
                dryRun: true,
            })),
            receipts: [],
        }
    }

    return {
        mode: "dry-run",
        targetActionMode: chainCfg.actionMode,
        executorAddress: null,
        proposals: [],
        receipts: batches.map((batch) => ({
            batchIndex: batch.batchIndex,
            txHash: null,
            from: null,
            to: batch.to,
            nonce: null,
            blockNumber: null,
            gasUsed: null,
            numAddresses: batch.numAddresses,
            sumRaw: batch.sumRaw,
            sumTokens: batch.sumTokens,
            dryRun: true,
        })),
    }
}

/*//////////////////////////////////////////////////////////////
                                MAIN
//////////////////////////////////////////////////////////////*/

async function main() {
    const cli = parseArgs(process.argv.slice(2))
    if (cli.showHelp) {
        printHelp()
        return
    }

    const chainCfg = chainConfigFromChainId(cli.chainId)
    const outputPaths = buildOutputPaths(cli.chainId)
    const revShareModuleDeployment = loadRevShareModuleDeployment(cli.chainId)
    const revShareModuleAbi = revShareModuleDeployment.abi
    const resolvedModule = await resolveRevShareModuleAddress(chainCfg, revShareModuleDeployment)
    const revShareModuleAddress = resolvedModule.address

    console.log("=== Run RevShare backfill batches ===")

    logSection("Configuration")
    console.log(`Chain: ${chainCfg.network} (${cli.chainId})`)
    console.log(`Target action: ${chainCfg.actionMode}`)
    console.log(`Dry run: ${cli.dryRun ? "enabled" : "disabled"}`)
    console.log(
        `RevShareModule: ${normalizeAddress(revShareModuleAddress)} (${resolvedModule.source})`,
    )
    console.log(`Allocations input: ${outputPaths.allocationsJson}`)
    console.log(`Report output: ${outputPaths.reportJson}`)

    if (!fs.existsSync(outputPaths.allocationsJson)) {
        throw new Error(
            `Allocations file not found at ${outputPaths.allocationsJson}. Run 02-buildRevShareBackfillAllocations.js with the same --chain first.`,
        )
    }

    const allocationsJson = JSON.parse(fs.readFileSync(outputPaths.allocationsJson, "utf8"))
    if (Number(allocationsJson.chainId) !== cli.chainId) {
        throw new Error(
            `Allocations file chainId ${allocationsJson.chainId} does not match --chain ${cli.chainId}.`,
        )
    }

    const allocations = allocationsJson.allocations || []
    const tokenDecimals = allocationsJson.tokenDecimals

    if (!Number.isInteger(tokenDecimals)) {
        throw new Error("tokenDecimals missing or not an integer in allocations JSON")
    }

    if (allocations.length === 0) {
        throw new Error("No allocations found in revshare_backfill_allocations.json")
    }

    logSection("Build Batches")
    console.log(`Loaded ${allocations.length} allocations (batch size = ${BATCH_SIZE})`)

    const batches = buildBatches({
        allocations,
        batchSize: BATCH_SIZE,
        tokenDecimals,
        moduleAddress: revShareModuleAddress,
        moduleAbi: revShareModuleAbi,
    })

    console.log(`Constructed ${batches.length} adminBackfillRevenue batch(es)`)

    let totalRaw = 0n
    for (const batch of batches) {
        totalRaw += BigInt(batch.sumRaw)
    }
    console.log(`Total batched amount: ${formatRaw(totalRaw, tokenDecimals)} tokens`)

    let actionResult

    const report = {
        chainId: cli.chainId,
        network: chainCfg.network,
        status: "prepared",
        actionMode: cli.dryRun ? "dry-run" : chainCfg.actionMode,
        targetActionMode: chainCfg.actionMode,
        dryRun: cli.dryRun,
        batchSize: BATCH_SIZE,
        tokenDecimals,
        revShareModule: normalizeAddress(revShareModuleAddress),
        revShareModuleSource: resolvedModule.source,
        allocationsFile: outputPaths.allocationsJson,
        totalAllocations: allocations.length,
        totalBatches: batches.length,
        totalAmountRaw: totalRaw.toString(),
        totalAmountTokens: formatRaw(totalRaw, tokenDecimals),
        safeAddress: null,
        proposerAddress: null,
        safeBaseNonce: null,
        txServiceUrl: null,
        executorAddress: null,
        proposals: [],
        receipts: [],
        batches,
    }
    writeReport(outputPaths.reportJson, report)

    const persistSafeProgress = (progress) => {
        report.status = "running"
        report.actionMode = progress.mode
        report.safeAddress = progress.safeAddress || report.safeAddress
        report.proposerAddress = progress.proposerAddress || report.proposerAddress
        report.safeBaseNonce =
            Number.isInteger(progress.baseNonce) || typeof progress.baseNonce === "number"
                ? progress.baseNonce
                : report.safeBaseNonce
        report.txServiceUrl = progress.txServiceUrl || report.txServiceUrl
        report.proposals.push(progress.proposal)
        writeReport(outputPaths.reportJson, report)
    }

    const persistSepoliaProgress = (progress) => {
        report.status = "running"
        report.actionMode = progress.mode
        report.executorAddress = progress.executorAddress || report.executorAddress
        report.receipts.push(progress.receipt)
        writeReport(outputPaths.reportJson, report)
    }

    try {
        if (cli.dryRun) {
            logSection("Dry Run Preview")
            actionResult = buildDryRunResult(batches, chainCfg)

            if (chainCfg.actionMode === "safe-proposal") {
                console.log("Dry run only. No Safe proposals were created.")
                console.log(`Safe address: ${actionResult.safeAddress}`)
                console.log(`Draft proposals: ${actionResult.proposals.length}`)
                for (const proposal of actionResult.proposals) {
                    console.log(
                        `Batch ${proposal.batchIndex}: would create Safe proposal addresses=${proposal.numAddresses} amount=${proposal.sumTokens}`,
                    )
                }
            } else {
                console.log("Dry run only. No onchain transactions were sent.")
                console.log(`Draft transactions: ${actionResult.receipts.length}`)
                for (const receipt of actionResult.receipts) {
                    console.log(
                        `Batch ${receipt.batchIndex}: would send tx to ${receipt.to} addresses=${receipt.numAddresses} amount=${receipt.sumTokens}`,
                    )
                }
            }
        } else if (cli.chainId === ARBITRUM_ONE_CHAIN_ID) {
            logSection("Create Safe Proposal")
            actionResult = await proposeToSafe(batches, chainCfg.rpcUrl, persistSafeProgress)
            console.log(`Safe address: ${actionResult.safeAddress}`)
            console.log(`Proposer address: ${actionResult.proposerAddress}`)
            console.log(`Base Safe nonce: ${actionResult.baseNonce}`)
            console.log(`Tx service URL: ${actionResult.txServiceUrl}`)
            console.log(`Proposals created: ${actionResult.proposals.length}`)
            for (const proposal of actionResult.proposals) {
                console.log(
                    `Batch ${proposal.batchIndex}: nonce=${proposal.nonce} safeTxHash=${proposal.safeTxHash} addresses=${proposal.numAddresses} amount=${proposal.sumTokens}`,
                )
            }
        } else {
            logSection("Send Onchain")
            actionResult = await executeOnSepolia(batches, chainCfg, persistSepoliaProgress)
            console.log(`Executor address: ${actionResult.executorAddress}`)
            console.log(`Transactions sent: ${actionResult.receipts.length}`)
            for (const receipt of actionResult.receipts) {
                console.log(
                    `Batch ${receipt.batchIndex}: txHash=${receipt.txHash} block=${receipt.blockNumber} gasUsed=${receipt.gasUsed}`,
                )
            }
        }
    } catch (error) {
        report.status = "failed"
        report.lastError = error?.message || String(error)
        writeReport(outputPaths.reportJson, report)
        throw error
    }

    report.status = "completed"
    report.actionMode = actionResult.mode
    report.targetActionMode = actionResult.targetActionMode || report.targetActionMode
    report.safeAddress = actionResult.safeAddress || report.safeAddress
    report.proposerAddress = actionResult.proposerAddress || report.proposerAddress
    report.safeBaseNonce =
        Number.isInteger(actionResult.baseNonce) || typeof actionResult.baseNonce === "number"
            ? actionResult.baseNonce
            : report.safeBaseNonce
    report.txServiceUrl = actionResult.txServiceUrl || report.txServiceUrl
    report.executorAddress = actionResult.executorAddress || report.executorAddress
    report.proposals = actionResult.proposals || report.proposals
    report.receipts = actionResult.receipts || report.receipts

    logSection("Write Report")
    writeReport(outputPaths.reportJson, report)
    console.log(`Report written to: ${outputPaths.reportJson}`)

    console.log("\nDone.")
}

main().catch((err) => {
    console.error("Error while processing RevShare backfill action:")
    console.error(err)
    process.exit(1)
})
