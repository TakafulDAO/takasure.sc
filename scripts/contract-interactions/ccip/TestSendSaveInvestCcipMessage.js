/*
JavaScript version of TestSendSaveInvestCcipMessage.s.sol.

It mints test SFUSDC to the caller (the wallet derived from NEW_USER_PRIVATE_KEY),
approves SaveInvestCCIPSender, and sends the CCIP message.

Required env vars:
  NEW_USER_ADDRESS
  NEW_USER_PRIVATE_KEY
  BASE_TESTNET_RPC_URL                  (used with --chain base)
  ETHEREUM_TESTNET_SEPOLIA_RPC_URL      (used with --chain eth)
  OPTIMISM_TESTNET_RPC_URL              (used with --chain opt)

Required args:
  --chain <eth|opt|base>
  --amount <raw_usdc_amount>

Flow:
  1. Parse --chain and --amount (USDC raw units, 6 decimals).
  2. Resolve the RPC URL from the env var mapped to --chain.
  3. Build the caller wallet from NEW_USER_PRIVATE_KEY and verify it matches NEW_USER_ADDRESS.
  4. Verify the RPC chainId matches the selected chain.
  5. Load SaveInvestCCIPSender and SFUSDCCcipTestnet deployment artifacts for that chain.
  6. Mint SFUSDC to the caller.
  7. Approve SaveInvestCCIPSender to spend the minted amount.
  8. Call sendMessage(PROTOCOL__SF_VAULT, amount, 600000).
  9. Print tx hashes, CCIP messageId (from event), and final balance.

Example:
  node scripts/contract-interactions/ccip/TestSendSaveInvestCcipMessage.js --chain opt --amount 100000000
*/

const fs = require("fs")
const path = require("path")
const { ethers } = require("ethers")
require("dotenv").config()

const DEFAULT_PROTOCOL_NAME = "PROTOCOL__SF_VAULT"
const MIN_AMOUNT = ethers.BigNumber.from("100000000") // 100e6
const MAX_GAS_LIMIT = ethers.BigNumber.from("600000")

const CHAIN_OPTIONS = {
    base: {
        name: "Base Sepolia",
        chainId: 84532,
        deploymentsDir: "testnet_base_sepolia",
        rpcEnvName: "BASE_TESTNET_RPC_URL",
    },
    eth: {
        name: "Ethereum Sepolia",
        chainId: 11155111,
        deploymentsDir: "testnet_ethereum_sepolia",
        rpcEnvName: "ETHEREUM_TESTNET_SEPOLIA_RPC_URL",
    },
    opt: {
        name: "Optimism Sepolia",
        chainId: 11155420,
        deploymentsDir: "testnet_optimism_sepolia",
        rpcEnvName: "OPTIMISM_TESTNET_RPC_URL",
    },
}

function requireEnv(name) {
    const value = process.env[name]
    if (!value || !value.trim()) {
        throw new Error(`Missing required env var: ${name}`)
    }
    return value.trim()
}

function getArg(name) {
    const idx = process.argv.indexOf(`--${name}`)
    if (idx === -1) return null
    const next = process.argv[idx + 1]
    if (!next || next.startsWith("--")) return null
    return next
}

function requireArg(name) {
    const value = getArg(name)
    if (!value) {
        throw new Error(`Missing required argument: --${name}`)
    }
    return value
}

function normalizePrivateKey(value) {
    const trimmed = value.trim()
    return trimmed.startsWith("0x") ? trimmed : `0x${trimmed}`
}

function parseBigNumber(value, label) {
    try {
        return ethers.BigNumber.from(value)
    } catch (_err) {
        throw new Error(`Invalid ${label}: ${value}`)
    }
}

function readDeploymentJson(deploymentsDir, contractName) {
    const filePath = path.resolve(__dirname, "..", "..", "..", "deployments", deploymentsDir, `${contractName}.json`)
    if (!fs.existsSync(filePath)) {
        throw new Error(`Deployment file not found: ${filePath}`)
    }

    const raw = fs.readFileSync(filePath, "utf8")
    const parsed = JSON.parse(raw)
    if (!parsed.address || !Array.isArray(parsed.abi)) {
        throw new Error(`Invalid deployment JSON: ${filePath}`)
    }
    return parsed
}

function parseOnTokensTransferred(receipt, senderInterface) {
    for (const log of receipt.logs) {
        try {
            const parsed = senderInterface.parseLog(log)
            if (parsed && parsed.name === "OnTokensTransferred") {
                return parsed.args
            }
        } catch (_err) {
            // Ignore logs from other contracts.
        }
    }
    return null
}

function printConfig({ caller, chainId, networkName, senderAddr, tokenAddr, protocolName, amount, ccipGasLimit, beforeBalance }) {
    console.log(`Network: ${networkName} (${chainId})`)
    console.log(`Caller: ${caller}`)
    console.log(`Sender: ${senderAddr}`)
    console.log(`Token: ${tokenAddr}`)
    console.log(`Protocol: ${protocolName}`)
    console.log(`Amount (raw): ${amount.toString()}`)
    console.log(`Amount (USDC): ${ethers.utils.formatUnits(amount, 6)}`)
    console.log(`GasLimit: ${ccipGasLimit.toString()}`)
    console.log(`Caller token balance before: ${beforeBalance.toString()}`)
}

async function main() {
    if (process.argv.includes("--help")) {
        console.log(
            [
                "Usage:",
                "  node scripts/contract-interactions/ccip/TestSendSaveInvestCcipMessage.js --chain <eth|opt|base> --amount <raw_usdc_amount>",
                "",
                "Examples:",
                "  node scripts/contract-interactions/ccip/TestSendSaveInvestCcipMessage.js --chain opt --amount 200000000",
                "  node scripts/contract-interactions/ccip/TestSendSaveInvestCcipMessage.js --chain eth --amount 100000000",
                "",
                "Env vars used by --chain:",
                "  --chain base -> BASE_TESTNET_RPC_URL",
                "  --chain eth  -> ETHEREUM_TESTNET_SEPOLIA_RPC_URL",
                "  --chain opt  -> OPTIMISM_TESTNET_RPC_URL",
                "",
                "Other required env vars:",
                "  NEW_USER_ADDRESS",
                "  NEW_USER_PRIVATE_KEY",
            ].join("\n"),
        )
        return
    }

    const chainArg = requireArg("chain").toLowerCase()
    const chainConfig = CHAIN_OPTIONS[chainArg]
    if (!chainConfig) {
        throw new Error(`Invalid --chain value: ${chainArg}. Allowed values: ${Object.keys(CHAIN_OPTIONS).join(", ")}`)
    }

    const rpcUrl = requireEnv(chainConfig.rpcEnvName)
    const expectedNewUserAddress = ethers.utils.getAddress(requireEnv("NEW_USER_ADDRESS"))
    const newUserPrivateKey = normalizePrivateKey(requireEnv("NEW_USER_PRIVATE_KEY"))
    const amount = parseBigNumber(requireArg("amount"), "--amount")
    const ccipGasLimit = MAX_GAS_LIMIT

    const provider = new ethers.providers.JsonRpcProvider(rpcUrl)
    const wallet = new ethers.Wallet(newUserPrivateKey, provider)
    const caller = ethers.utils.getAddress(wallet.address)

    if (caller !== expectedNewUserAddress) {
        throw new Error(
            `NEW_USER_ADDRESS (${expectedNewUserAddress}) does not match address derived from NEW_USER_PRIVATE_KEY (${caller})`,
        )
    }

    const network = await provider.getNetwork()
    if (network.chainId !== chainConfig.chainId) {
        throw new Error(
            `RPC chain mismatch for --chain ${chainArg}. Expected chainId ${chainConfig.chainId} (${chainConfig.name}), got ${network.chainId}`,
        )
    }

    const protocolName = DEFAULT_PROTOCOL_NAME

    if (amount.lt(MIN_AMOUNT)) {
        throw new Error(`Invalid amount: ${amount.toString()} (minimum is ${MIN_AMOUNT.toString()})`)
    }
    if (ccipGasLimit.gt(MAX_GAS_LIMIT)) {
        throw new Error(`Gas limit too high: ${ccipGasLimit.toString()} (maximum is ${MAX_GAS_LIMIT.toString()})`)
    }

    const senderDeployment = readDeploymentJson(chainConfig.deploymentsDir, "SaveInvestCCIPSender")
    const tokenDeployment = readDeploymentJson(chainConfig.deploymentsDir, "SFUSDCCcipTestnet")

    const sender = new ethers.Contract(senderDeployment.address, senderDeployment.abi, wallet)
    const token = new ethers.Contract(tokenDeployment.address, tokenDeployment.abi, wallet)

    const beforeBalance = await token.balanceOf(caller)
    printConfig({
        caller,
        chainId: network.chainId,
        networkName: chainConfig.name,
        senderAddr: sender.address,
        tokenAddr: token.address,
        protocolName,
        amount,
        ccipGasLimit,
        beforeBalance,
    })

    const mintTx = await token.mintUSDC(caller, amount)
    const mintReceipt = await mintTx.wait()
    console.log(`mint tx hash: ${mintReceipt.transactionHash}`)

    const approveTx = await token.approve(sender.address, amount)
    const approveReceipt = await approveTx.wait()
    console.log(`approve tx hash: ${approveReceipt.transactionHash}`)

    const sendTx = await sender.sendMessage(protocolName, amount, ccipGasLimit)
    const sendReceipt = await sendTx.wait()
    console.log(`sendMessage tx hash: ${sendReceipt.transactionHash}`)

    const transferEvent = parseOnTokensTransferred(sendReceipt, sender.interface)
    if (transferEvent && transferEvent.messageId) {
        console.log("CCIP messageId:")
        console.log(transferEvent.messageId)
    } else {
        console.log("CCIP messageId: not found in receipt logs (check OnTokensTransferred event)")
    }

    const afterBalance = await token.balanceOf(caller)
    console.log(`Caller token balance after: ${afterBalance.toString()}`)
}

main().catch((err) => {
    console.error(err?.message || err)
    if (err?.error?.message) {
        console.error(`RPC error: ${err.error.message}`)
    }
    process.exit(1)
})
