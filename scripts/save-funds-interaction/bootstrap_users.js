require("dotenv").config()

const fs = require("fs")
const path = require("path")
const XLSX = require("xlsx")
const { ethers } = require("ethers")

// Addresses in Arbitrum Sepolia
const ADDR = {
    SFVault: "0x42eFc18C181CBDa3108E95c7080E8B9564dCD86a",
    SFStrategyAggregator: "0xaa0F42417a971642a6eA81134fd47d4B5097b0d6",
    SFUniswapStrategy: "0xdB3177CF90cF7d24cc335C2049AECb96c3B81D8E",
    UniswapV3MathHelper: "0x7178164e984352c279B31EAe83a4a13578F83AcA",
    SFUSDC: "0x2fE9378AF2f1aeB8b013031d1a3567F6E0d44dA1",
    SFUSDT: "0x27a59b95553BE7D51103E772A713f0A15d447356",
    Pool_USDC_USDT: "0x51dff4A270295C78CA668c3B6a8b427269AeaA7f",
    AddressManager: "0x570089AcFD6d07714A7A9aC25A74880e69546656",
    RolesEOA: "0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1",
}

const ERC20_ABI = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function balanceOf(address account) external view returns (uint256)",
    "function decimals() external view returns (uint8)",
    "function symbol() external view returns (string)",
]

const SFUSDC_ABI = [...ERC20_ABI, "function mintUSDC(address to, uint256 amount) external"]

const SFVault_ABI = [
    "function asset() external view returns (address)",
    "function registerMember(address newMember) external",
    "function deposit(uint256 assets, address receiver) external returns (uint256)",
    "function balanceOf(address owner) external view returns (uint256)",
    "function totalAssets() external view returns (uint256)",
]

function argValue(flag, def) {
    const i = process.argv.indexOf(flag)
    if (i === -1) return def
    const v = process.argv[i + 1]
    if (!v || v.startsWith("--")) return def
    return v
}

function argHas(flag) {
    return process.argv.includes(flag)
}

function ensureDir(p) {
    if (!fs.existsSync(p)) fs.mkdirSync(p, { recursive: true })
}

function resolveOutDir() {
    // Priority:
    // 1) CLI: --outDir
    // 2) ENV: SF_BOOTSTRAP_OUT_DIR
    // 3) Default: <this script folder>/users_out
    const cli = argValue("--outDir", "")
    const env = process.env.SF_BOOTSTRAP_OUT_DIR || ""
    const base = cli || env
    const scriptDir = __dirname

    const resolved = base
        ? path.isAbsolute(base)
            ? base
            : path.resolve(process.cwd(), base)
        : path.join(scriptDir, "users_out")

    ensureDir(resolved)
    return resolved
}

function resolveUsersJsonPath() {
    // Optional: if set, we'll LOAD existing users instead of generating new ones.
    // Priority:
    // 1) CLI: --usersJson
    // 2) ENV: SF_BOOTSTRAP_USERS_JSON
    const cli = argValue("--usersJson", "")
    const env = process.env.SF_BOOTSTRAP_USERS_JSON || ""
    const p = cli || env
    if (!p) return ""
    return path.isAbsolute(p) ? p : path.resolve(process.cwd(), p)
}

async function runBatched(items, batchSize, fn) {
    const results = []
    for (let i = 0; i < items.length; i += batchSize) {
        const batch = items.slice(i, i + batchSize)
        const out = await Promise.all(
            batch.map(async (x) => {
                try {
                    return await fn(x)
                } catch (e) {
                    return {
                        ok: false,
                        error: e?.error?.message || e?.reason || e?.message || String(e),
                    }
                }
            }),
        )
        results.push(...out)
    }
    return results
}

// Send back test ETH from user back to funder EOA
async function refundAllEthBack(userWallet, rolesEOA, provider) {
    const feeData = await provider.getFeeData()

    const maxFeePerGas =
        feeData.maxFeePerGas || feeData.gasPrice || ethers.utils.parseUnits("0.1", "gwei")
    const maxPriorityFeePerGas =
        feeData.maxPriorityFeePerGas || ethers.utils.parseUnits("0.01", "gwei")

    const bal = await provider.getBalance(userWallet.address)
    if (bal.isZero()) return { sent: false, reason: "zero balance" }

    const gasLimit = ethers.BigNumber.from(21000)
    const safety = ethers.utils.parseEther("0.00002") // 0.00002 ETH

    const feeReserve = gasLimit.mul(maxFeePerGas).add(safety)
    if (bal.lte(feeReserve)) {
        return { sent: false, reason: "not enough to refund after reserving gas" }
    }

    const value = bal.sub(feeReserve)

    const txReq = { to: rolesEOA, value, gasLimit }
    if (feeData.maxFeePerGas) {
        txReq.maxFeePerGas = maxFeePerGas
        txReq.maxPriorityFeePerGas = maxPriorityFeePerGas
    } else if (feeData.gasPrice) {
        txReq.gasPrice = feeData.gasPrice
    }

    const tx = await userWallet.sendTransaction(txReq)
    const receipt = await tx.wait(1)
    return { sent: true, value, hash: receipt.transactionHash }
}

async function main() {
    const RPC_URL = process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    const ROLES_PK = process.env.TESTNET_PK

    if (!RPC_URL) throw new Error("Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL in .env")
    if (!ROLES_PK) throw new Error("Missing TESTNET_PK in .env")

    const COUNT = Number(argValue("--count", "100"))
    const FUND_ETH = argValue("--fund", "0.01") // per user
    const DEPOSIT_USDC = argValue("--deposit", "100") // per user (whole units, 6 decimals)
    const USER_BATCH = Number(argValue("--userBatch", "10"))
    const SKIP_REFUND = argHas("--skipRefund")

    const OUT_DIR = resolveOutDir()
    const USERS_JSON_IN = resolveUsersJsonPath()

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL)
    const rolesWallet = new ethers.Wallet(ROLES_PK, provider)

    console.log("Roles EOA:", rolesWallet.address)
    if (rolesWallet.address.toLowerCase() !== ADDR.RolesEOA.toLowerCase()) {
        console.warn("WARNING: ROLES_PK does not match expected RolesEOA address:", ADDR.RolesEOA)
    }

    const net = await provider.getNetwork()
    console.log("Connected chainId:", net.chainId)
    if (net.chainId !== 421614) {
        console.warn("WARNING: This is not Arbitrum Sepolia (421614).")
    }

    const vault = new ethers.Contract(ADDR.SFVault, SFVault_ABI, provider)
    const usdc = new ethers.Contract(ADDR.SFUSDC, SFUSDC_ABI, provider)

    const vaultAsset = await vault.asset()
    if (vaultAsset.toLowerCase() !== ADDR.SFUSDC.toLowerCase()) {
        throw new Error(`Vault.asset() mismatch. Expected ${ADDR.SFUSDC}, got ${vaultAsset}`)
    }

    const usdcDecimals = await usdc.decimals()
    const usdcSymbol = await usdc.symbol().catch(() => "SFUSDC")
    console.log("Vault asset OK:", usdcSymbol, "decimals:", usdcDecimals)

    const depositUnits = ethers.utils.parseUnits(DEPOSIT_USDC, usdcDecimals)
    const fundUnits = ethers.utils.parseEther(FUND_ETH)

    // 1) Load existing users OR generate new ones
    let users = []
    let jsonPath = ""
    let xlsxPath = ""

    if (USERS_JSON_IN && fs.existsSync(USERS_JSON_IN)) {
        console.log(`\nLoading users from: ${USERS_JSON_IN}`)
        users = JSON.parse(fs.readFileSync(USERS_JSON_IN, "utf8"))

        if (!Array.isArray(users) || !users.length) throw new Error("Users JSON is empty/invalid.")
        // normalize idx if missing
        users = users.map((u, i) => ({
            idx: u.idx ?? i,
            address: u.address,
            privateKey: u.privateKey,
        }))
        console.log(`Loaded ${users.length} users.`)
    } else {
        console.log(`\nGenerating ${COUNT} wallets...`)
        for (let i = 0; i < COUNT; i++) {
            const w = ethers.Wallet.createRandom()
            users.push({ idx: i, address: w.address, privateKey: w.privateKey })
        }

        // 2) Save users to JSON + XLSX in OUT_DIR
        const ts = new Date().toISOString().replace(/[:.]/g, "-")
        jsonPath = path.join(OUT_DIR, `users_${users.length}_${ts}.json`)
        xlsxPath = path.join(OUT_DIR, `users_${users.length}_${ts}.xlsx`)

        fs.writeFileSync(jsonPath, JSON.stringify(users, null, 2))
        console.log("Wrote:", jsonPath)

        const sheetRows = users.map((u) => ({
            idx: u.idx,
            address: u.address,
            privateKey: u.privateKey,
            depositUSDC: DEPOSIT_USDC,
            fundETH: FUND_ETH,
        }))

        const wb = XLSX.utils.book_new()
        const ws = XLSX.utils.json_to_sheet(sheetRows)
        XLSX.utils.book_append_sheet(wb, ws, "users")
        XLSX.writeFile(wb, xlsxPath)
        console.log("Wrote:", xlsxPath)

        const latestJson = path.join(OUT_DIR, "users_latest.json")
        const latestXlsx = path.join(OUT_DIR, "users_latest.xlsx")
        fs.copyFileSync(jsonPath, latestJson)
        fs.copyFileSync(xlsxPath, latestXlsx)
        console.log("Wrote:", latestJson)
        console.log("Wrote:", latestXlsx)

        console.log("\nTip: add this to your .env for future runs:")
        console.log(`SF_BOOTSTRAP_USERS_JSON=${path.relative(process.cwd(), latestJson)}`)
    }

    // 3) Fund each user
    console.log(`\nFunding ${users.length} users with ${FUND_ETH} ETH each...`)
    for (const u of users) {
        const tx = await rolesWallet.sendTransaction({ to: u.address, value: fundUnits })
        await tx.wait(1)
        if (u.idx % 10 === 0) console.log(`  funded ${u.idx}/${users.length - 1}`)
    }
    console.log("Funding complete.")

    // 4) Register members
    console.log("\nRegistering members on SFVault...")
    const vaultAsRoles = vault.connect(rolesWallet)
    for (const u of users) {
        const tx = await vaultAsRoles.registerMember(u.address)
        await tx.wait(1)
        if (u.idx % 10 === 0) console.log(`  registered ${u.idx}/${users.length - 1}`)
    }
    console.log("Member registration complete.")

    // 5) Mint USDC to users
    console.log(`\nMinting ${DEPOSIT_USDC} ${usdcSymbol} to each user...`)
    const usdcAsRoles = usdc.connect(rolesWallet)
    for (const u of users) {
        const tx = await usdcAsRoles.mintUSDC(u.address, depositUnits)
        await tx.wait(1)
        if (u.idx % 10 === 0) console.log(`  minted ${u.idx}/${users.length - 1}`)
    }
    console.log("Minting complete.")

    // 6) Each user approves + deposits
    console.log(`\nUsers approving + depositing into SFVault in batches of ${USER_BATCH}...`)

    const userResults = await runBatched(users, USER_BATCH, async (u) => {
        const userWallet = new ethers.Wallet(u.privateKey, provider)
        const usdcAsUser = usdc.connect(userWallet)
        const vaultAsUser = vault.connect(userWallet)

        const tx1 = await usdcAsUser.approve(ADDR.SFVault, depositUnits)
        await tx1.wait(1)

        const tx2 = await vaultAsUser.deposit(depositUnits, userWallet.address)
        const r2 = await tx2.wait(1)

        return { ok: true, idx: u.idx, address: u.address, depositTx: r2.transactionHash }
    })

    const okDeposits = userResults.filter((r) => r.ok).length
    const badDeposits = userResults.length - okDeposits
    console.log(`Deposits done. ok=${okDeposits} failed=${badDeposits}`)
    if (badDeposits > 0) {
        console.log("Some deposit failures (first 5):")
        userResults
            .filter((r) => !r.ok)
            .slice(0, 5)
            .forEach((r) => console.log("  ", r))
    }

    // 7) Refund ETH back to roles EOA
    if (!SKIP_REFUND) {
        console.log("\nRefunding leftover ETH back to roles EOA (after deposits)...")
        const refundResults = await runBatched(users, USER_BATCH, async (u) => {
            const userWallet = new ethers.Wallet(u.privateKey, provider)
            const res = await refundAllEthBack(userWallet, rolesWallet.address, provider)
            return { ok: true, idx: u.idx, address: u.address, ...res }
        })

        const refunded = refundResults.filter((r) => r.sent).length
        console.log(`Refund complete. refunded=${refunded}/${users.length}`)

        const sample = refundResults
            .filter((r) => r.sent)
            .slice(0, 3)
            .map((r) => ({
                idx: r.idx,
                address: r.address,
                valueETH: ethers.utils.formatEther(r.value),
                hash: r.hash,
            }))
        if (sample.length) console.log("Refund sample:", sample)
    } else {
        console.log("\n--skipRefund used; not refunding ETH.")
    }

    // 8) Quick sanity prints
    const totalAssets = await vault.totalAssets()
    console.log(
        "\nSFVault.totalAssets():",
        ethers.utils.formatUnits(totalAssets, usdcDecimals),
        usdcSymbol,
    )

    for (const u of users.slice(0, 3)) {
        const shares = await vault.balanceOf(u.address)
        console.log(`Shares[user ${u.idx}]:`, shares.toString())
    }

    console.log("\nDONE.")
    console.log("Out dir:", OUT_DIR)
    if (jsonPath) {
        console.log("User files:")
        console.log("  JSON:", jsonPath)
        console.log("  XLSX:", xlsxPath)
    } else {
        console.log("Used existing users JSON.")
    }
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})

/*
Examples:

node scripts/save-funds-interaction/bootstrap_users.js

node scripts/save-funds-interaction/bootstrap_users.js --count 100 --fund 0.01 --deposit 100 --userBatch 10

Use a custom output directory:
node scripts/save-funds-interaction/bootstrap_users.js --outDir ./scripts/save-funds-interaction/users_out

Reuse an existing users JSON (no regen):
node scripts/save-funds-interaction/bootstrap_users.js --usersJson ./scripts/save-funds-interaction/users_out/users_latest.json

Skip refunds:
node scripts/save-funds-interaction/bootstrap_users.js --skipRefund
*/
