require("dotenv").config()

const { ethers } = require("ethers")

const ADDR = {
    SFVault: "0x42eFc18C181CBDa3108E95c7080E8B9564dCD86a",
    SFStrategyAggregator: "0xaa0F42417a971642a6eA81134fd47d4B5097b0d6",
    SFUniswapStrategy: "0xdB3177CF90cF7d24cc335C2049AECb96c3B81D8E",
    SFUSDC: "0x2fE9378AF2f1aeB8b013031d1a3567F6E0d44dA1",
    Pool_USDC_USDT: "0x51dff4A270295C78CA668c3B6a8b427269AeaA7f",
    AddressManager: "0x570089AcFD6d07714A7A9aC25A74880e69546656",
}

const AddressManager_ABI = [
    "function owner() external view returns (address)",
    "function hasRole(bytes32 role, address account) external view returns (bool)",
    "function hasName(string name, address addr) external view returns (bool)",
]

const SFVault_ABI = [
    "function totalAssets() external view returns (uint256)",
    "function paused() external view returns (bool)",
    "function investIntoStrategy(uint256 assets, address[] strategies, bytes[] payloads) external returns (uint256)",
    "function withdrawFromStrategy(uint256 assets, address[] strategies, bytes[] payloads) external returns (uint256)",
    "function setERC721ApprovalForAll(address nft, address operator, bool approved) external",
]

const Aggregator_ABI = [
    "function totalAssets() external view returns (uint256)",
    "function paused() external view returns (bool)",
    "function harvest(bytes data) external",
    "function rebalance(bytes data) external",
    "function getSubStrategies() external view returns ((address strategy,uint16 targetWeightBPS,bool isActive)[] out)",
]

const UniV3Strategy_ABI = [
    "function totalAssets() external view returns (uint256)",
    "function paused() external view returns (bool)",
    "function positionTokenId() external view returns (uint256)",
    "function vault() external view returns (address)",
    "function pool() external view returns (address)",
]

const ERC20_ABI = [
    "function decimals() external view returns (uint8)",
    "function symbol() external view returns (string)",
]

const V3Pool_ABI = [
    "function slot0() external view returns (uint160 sqrtPriceX96,int24 tick,uint16 observationIndex,uint16 observationCardinality,uint16 observationCardinalityNext,uint8 feeProtocol,bool unlocked)",
    "function tickSpacing() external view returns (int24)",
    "function token0() external view returns (address)",
    "function token1() external view returns (address)",
]

const ERC721_ABI = [
    "function isApprovedForAll(address owner, address operator) external view returns (bool)",
]

// ----------------- args -----------------
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

// ----------------- tick helpers -----------------
function roundUpToSpacing(tick, spacing) {
    const rem = tick % spacing
    if (rem === 0) return tick
    if (tick >= 0) return tick + (spacing - rem)
    return tick - rem // toward zero
}
function roundDownToSpacing(tick, spacing) {
    const rem = tick % spacing
    if (rem === 0) return tick
    if (tick >= 0) return tick - rem
    return tick - (spacing + rem) // more negative
}

// ----------------- revert decoding -----------------
function mkSelectorMap() {
    const sigs = [
        "SFStrategyAggregator__NotAuthorizedCaller()",
        "SFStrategyAggregator__InvalidPerStrategyData()",
        "SFStrategyAggregator__UnknownPerStrategyDataStrategy()",
        "SFStrategyAggregator__DuplicatePerStrategyDataStrategy()",
        "SFUniswapV3Strategy__NotAuthorizedCaller()",
        "SFUniswapV3Strategy__VaultNotApprovedForNFT()",
        "SFUniswapV3Strategy__InvalidTicks()",
        "SFUniswapV3Strategy__InvalidRebalanceParams()",
        "SFUniswapV3Strategy__NoPosition()",
        "SFUniswapV3Strategy__InvalidDeadline()",
        "SFVault__NotAuthorizedCaller()",
    ]

    const map = {}
    for (const s of sigs) {
        const sel = ethers.utils.id(s).slice(0, 10)
        map[sel] = s
    }
    map["0x82b42900"] = "AccessControlUnauthorizedAccount(address,bytes32)"
    return map
}
const SELECTOR_MAP = mkSelectorMap()

function tryParseJson(s) {
    try {
        return JSON.parse(s)
    } catch {
        return null
    }
}

function getRevertDataFromError(err) {
    const direct =
        err?.error?.data || err?.data || err?.error?.error?.data || err?.error?.error?.error?.data

    if (direct && typeof direct === "string") return direct

    const bodyStr = err?.error?.body || err?.body
    if (typeof bodyStr === "string") {
        const body = tryParseJson(bodyStr)
        const data =
            body?.error?.data || body?.error?.data?.data || body?.error?.error?.data || body?.result
        if (typeof data === "string") return data
        if (typeof data?.data === "string") return data.data
    }

    return null
}

function decodeRevert(dataHex) {
    if (!dataHex || typeof dataHex !== "string") return { kind: "unknown", dataHex }
    if (dataHex === "0x") return { kind: "empty-revert-data", dataHex }

    if (!dataHex.startsWith("0x")) return { kind: "unknown", dataHex }

    // Error(string)
    if (dataHex.startsWith("0x08c379a0")) {
        try {
            const reason = ethers.utils.defaultAbiCoder.decode(["string"], "0x" + dataHex.slice(10))
            return { kind: "Error(string)", reason: reason[0], dataHex }
        } catch {
            return { kind: "Error(string)", reason: "<failed to decode>", dataHex }
        }
    }

    // Panic(uint256)
    if (dataHex.startsWith("0x4e487b71")) {
        try {
            const code = ethers.utils.defaultAbiCoder.decode(["uint256"], "0x" + dataHex.slice(10))
            return { kind: "Panic(uint256)", code: code[0].toString(), dataHex }
        } catch {
            return { kind: "Panic(uint256)", code: "<failed to decode>", dataHex }
        }
    }

    const sel = dataHex.slice(0, 10)
    const sig = SELECTOR_MAP[sel]
    if (sig) return { kind: "custom", selector: sel, signature: sig, dataHex }
    return { kind: "custom-unknown", selector: sel, dataHex }
}

function logCallStaticError(label, err) {
    const rd = getRevertDataFromError(err)
    console.log(`  ❌ ${label} reverted`)
    console.log("  code:", err?.code || "<no code>")
    console.log("  message:", err?.message || "<no message>")
    console.log("  decoded:", decodeRevert(rd ?? "0x"))
    if (rd == null) {
        console.log("  (no revert data extracted from error object)")
    }
}

async function ethCallWithGas(provider, txReq, label) {
    try {
        await provider.call(txReq)
        console.log(`  ✅ ${label} OK`)
        return true
    } catch (e) {
        logCallStaticError(label, e)
        return false
    }
}

// ----------------- main -----------------
async function main() {
    const RPC_URL = process.env.ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    const ROLES_PK = process.env.TESTNET_PK
    if (!RPC_URL) throw new Error("Missing ARBITRUM_TESTNET_SEPOLIA_RPC_URL in .env")
    if (!ROLES_PK) throw new Error("Missing TESTNET_PK in .env")

    const INVEST_USDC = argValue("--invest", "2000")
    const WITHDRAW_USDC = argValue("--withdraw", "0")

    const DO_REBALANCE = !argHas("--noRebalance")
    const DO_HARVEST = !argHas("--noHarvest")
    const SKIP_APPROVAL = argHas("--skipApproval")
    const FORCE_SEND = argHas("--force")

    // How much gas to give eth_call simulations
    const STATIC_GAS = ethers.BigNumber.from(argValue("--staticGas", "15000000"))

    const provider = new ethers.providers.JsonRpcProvider(RPC_URL)
    const rolesWallet = new ethers.Wallet(ROLES_PK, provider)

    console.log("Roles EOA:", rolesWallet.address)
    const net = await provider.getNetwork()
    console.log("Connected chainId:", net.chainId)

    const am = new ethers.Contract(ADDR.AddressManager, AddressManager_ABI, provider)
    const vault = new ethers.Contract(ADDR.SFVault, SFVault_ABI, rolesWallet)
    const agg = new ethers.Contract(ADDR.SFStrategyAggregator, Aggregator_ABI, rolesWallet)
    const uni = new ethers.Contract(ADDR.SFUniswapStrategy, UniV3Strategy_ABI, provider)

    const usdc = new ethers.Contract(ADDR.SFUSDC, ERC20_ABI, provider)
    const pool = new ethers.Contract(ADDR.Pool_USDC_USDT, V3Pool_ABI, provider)

    const usdcDecimals = await usdc.decimals()
    const usdcSymbol = await usdc.symbol().catch(() => "SFUSDC")

    console.log("\n[Preflight] Paused flags:")
    console.log("  vault.paused():", await vault.paused().catch(() => "<no paused()>"))
    console.log("  agg.paused():  ", await agg.paused().catch(() => "<no paused()>"))
    console.log("  uni.paused():  ", await uni.paused().catch(() => "<no paused()>"))

    console.log("\n[Preflight] AddressManager name checks:")
    console.log(
        "  hasName(PROTOCOL__SF_AGGREGATOR, agg):",
        await am.hasName("PROTOCOL__SF_AGGREGATOR", ADDR.SFStrategyAggregator),
    )
    console.log(
        "  hasName(PROTOCOL__SF_VAULT, vault):   ",
        await am.hasName("PROTOCOL__SF_VAULT", ADDR.SFVault),
    )

    // Minimal role sanity (cheap + avoids chasing ghosts)
    const KEEPER = ethers.utils.id("KEEPER")
    const OPERATOR = ethers.utils.id("OPERATOR")
    console.log("\n[Preflight] Roles sanity:")
    console.log("  hasRole(KEEPER, rolesEOA):  ", await am.hasRole(KEEPER, rolesWallet.address))
    console.log("  hasRole(OPERATOR, rolesEOA):", await am.hasRole(OPERATOR, rolesWallet.address))

    const uniVault = await uni.vault()
    const uniPool = await uni.pool()
    console.log("\n[Preflight] Uni strategy config:")
    console.log(
        "  uni.vault():",
        uniVault,
        uniVault.toLowerCase() === ADDR.SFVault.toLowerCase() ? "(matches)" : "(MISMATCH!)",
    )
    console.log(
        "  uni.pool(): ",
        uniPool,
        uniPool.toLowerCase() === ADDR.Pool_USDC_USDT.toLowerCase() ? "(matches)" : "(MISMATCH!)",
    )

    // ----------------- approval -----------------
    if (SKIP_APPROVAL) {
        console.log("\n[Approval] --skipApproval used; skipping approval check.")
    } else {
        console.log("\n[Approval] Checking vault -> strategy approval on PositionManager...")
        // read PositionManager from storage slot2 (as you already do)
        const pmWord = await provider.getStorageAt(ADDR.SFUniswapStrategy, 2)
        const positionManagerAddr = ethers.utils.getAddress("0x" + pmWord.slice(26))
        console.log("  positionManager:", positionManagerAddr)

        const pmNFT = new ethers.Contract(positionManagerAddr, ERC721_ABI, provider)
        const approved = await pmNFT.isApprovedForAll(uniVault, ADDR.SFUniswapStrategy)
        console.log("  isApprovedForAll(uniVault, strategy):", approved)

        if (!approved) {
            console.log("  approval missing -> calling vault.setERC721ApprovalForAll(...)")
            const txAppr = await vault.setERC721ApprovalForAll(
                positionManagerAddr,
                ADDR.SFUniswapStrategy,
                true,
                {
                    gasLimit: 700_000,
                },
            )
            console.log("  tx:", txAppr.hash)
            await txAppr.wait(1)
            console.log("  approval set ✅")
        } else {
            console.log("  approval already set ✅")
        }
    }

    // ----------------- pool / ticks -----------------
    const slot0 = await pool.slot0()
    const currentTick = Number(slot0.tick.toString())
    const spacing = Number((await pool.tickSpacing()).toString())
    const token0 = await pool.token0()
    const token0IsUSDC = token0.toLowerCase() === ADDR.SFUSDC.toLowerCase()

    const latestBlock = await provider.getBlock("latest")
    const pmDeadline = Number(latestBlock.timestamp) + 3600

    const offset = spacing * 10
    const width = spacing * 200

    let newTickLower, newTickUpper
    if (token0IsUSDC) {
        newTickLower = roundUpToSpacing(currentTick + offset, spacing)
        newTickUpper = newTickLower + width
    } else {
        newTickUpper = roundDownToSpacing(currentTick - offset, spacing)
        newTickLower = newTickUpper - width
    }

    console.log("\n[Rebalance] Params:")
    console.log("  poolTick:", currentTick, "spacing:", spacing, "token0IsUSDC:", token0IsUSDC)
    console.log("  ticks:", newTickLower, newTickUpper)
    console.log("  deadline:", pmDeadline)

    const rebalancePayload = ethers.utils.defaultAbiCoder.encode(
        ["int24", "int24", "uint256", "uint256", "uint256"],
        [newTickLower, newTickUpper, pmDeadline, 0, 0],
    )
    const rebalanceData = ethers.utils.defaultAbiCoder.encode(
        ["address[]", "bytes[]"],
        [[ADDR.SFUniswapStrategy], [rebalancePayload]],
    )

    // ----------------- rebalance -----------------
    if (!DO_REBALANCE) {
        console.log("\n[Rebalance] --noRebalance used; skipping.")
    } else {
        console.log("\n[Rebalance] callStatic agg.rebalance(...) ...")

        const txReq = {
            to: ADDR.SFStrategyAggregator,
            from: rolesWallet.address,
            data: agg.interface.encodeFunctionData("rebalance", [rebalanceData]),
            gasLimit: STATIC_GAS,
        }

        const ok = await ethCallWithGas(provider, txReq, "callStatic agg.rebalance")

        if (!ok && !FORCE_SEND) {
            console.log(
                "  Tip: empty revert data usually means eth_call gas cap / OOG / RPC not returning data.",
            )
            console.log("  Try: --staticGas 25000000  OR just send with --force.")
            return
        }

        if (!ok && FORCE_SEND) {
            console.log("  --force set: sending tx anyway...")
        }

        console.log("\n[Rebalance] Sending agg.rebalance(...) ...")
        const txReb = await agg.rebalance(rebalanceData, { gasLimit: 5_000_000 })
        console.log("  tx:", txReb.hash)
        const rec = await txReb.wait(1)
        console.log("  status:", rec.status, rec.status === 1 ? "✅" : "❌")
        if (rec.status !== 1) return
    }

    // ----------------- invest -----------------
    const investNum = Number(INVEST_USDC)
    if (investNum <= 0) {
        console.log("\n[Invest] --invest 0 used; skipping.")
    } else {
        console.log("\n[Invest] Investing from vault into active strategies...")
        const investAmount = ethers.utils.parseUnits(INVEST_USDC, usdcDecimals)

        // Uni deposit encoding
        const v3DepositData = ethers.utils.defaultAbiCoder.encode(
            ["uint16", "bytes", "bytes", "uint256", "uint256", "uint256"],
            [0, "0x", "0x", pmDeadline, 0, 0],
        )

        const active = (await agg.getSubStrategies()).filter((s) => s.isActive)
        const strategies = active.map((s) => s.strategy)
        const payloads = active.map((s) =>
            s.strategy.toLowerCase() === ADDR.SFUniswapStrategy.toLowerCase()
                ? v3DepositData
                : "0x",
        )

        console.log("  active strategies:", strategies.length)

        console.log("  callStatic vault.investIntoStrategy(...) ...")
        const txReqInv = {
            to: ADDR.SFVault,
            from: rolesWallet.address,
            data: vault.interface.encodeFunctionData("investIntoStrategy", [
                investAmount,
                strategies,
                payloads,
            ]),
            gasLimit: STATIC_GAS,
        }

        const okInv = await ethCallWithGas(
            provider,
            txReqInv,
            "callStatic vault.investIntoStrategy",
        )
        if (!okInv && !FORCE_SEND) return
        if (!okInv && FORCE_SEND) console.log("  --force set: sending tx anyway...")

        const txInv = await vault.investIntoStrategy(investAmount, strategies, payloads, {
            gasLimit: 6_000_000,
        })
        console.log("  tx:", txInv.hash)
        await txInv.wait(1)
        console.log("  invest done ✅")
    }

    // ----------------- harvest -----------------
    if (!DO_HARVEST) {
        console.log("\n[Harvest] --noHarvest used; skipping.")
    } else {
        console.log("\n[Harvest] Harvesting (agg.harvest with empty data)...")
        console.log("  callStatic agg.harvest(...) ...")

        const txReqHar = {
            to: ADDR.SFStrategyAggregator,
            from: rolesWallet.address,
            data: agg.interface.encodeFunctionData("harvest", ["0x"]),
            gasLimit: STATIC_GAS,
        }

        const okHar = await ethCallWithGas(provider, txReqHar, "callStatic agg.harvest")
        if (!okHar && !FORCE_SEND) return
        if (!okHar && FORCE_SEND) console.log("  --force set: sending tx anyway...")

        const txHar = await agg.harvest("0x", { gasLimit: 5_000_000 })
        console.log("  tx:", txHar.hash)
        await txHar.wait(1)
        console.log("  harvest done ✅")
    }

    // ----------------- withdraw (optional) -----------------
    const withdrawNum = Number(WITHDRAW_USDC)
    if (withdrawNum > 0) {
        console.log("\n[Withdraw] Withdrawing from strategies back to vault...")
        const withdrawAmount = ethers.utils.parseUnits(WITHDRAW_USDC, usdcDecimals)

        const active = (await agg.getSubStrategies()).filter((s) => s.isActive)
        const strategies = active.map((s) => s.strategy)
        const payloads = strategies.map(() => "0x")

        console.log("  callStatic vault.withdrawFromStrategy(...) ...")
        const txReqW = {
            to: ADDR.SFVault,
            from: rolesWallet.address,
            data: vault.interface.encodeFunctionData("withdrawFromStrategy", [
                withdrawAmount,
                strategies,
                payloads,
            ]),
            gasLimit: STATIC_GAS,
        }

        const okW = await ethCallWithGas(provider, txReqW, "callStatic vault.withdrawFromStrategy")
        if (!okW && !FORCE_SEND) return
        if (!okW && FORCE_SEND) console.log("  --force set: sending tx anyway...")

        const txW = await vault.withdrawFromStrategy(withdrawAmount, strategies, payloads, {
            gasLimit: 6_000_000,
        })
        console.log("  tx:", txW.hash)
        await txW.wait(1)
        console.log("  withdraw done ✅")
    } else {
        console.log("\n[Withdraw] No withdraw requested.")
    }

    // ----------------- metrics -----------------
    console.log("\n[Metrics]")
    const vTA = await vault.totalAssets()
    const aTA = await agg.totalAssets()
    const uTA = await uni.totalAssets()
    console.log("  vault.totalAssets:", ethers.utils.formatUnits(vTA, usdcDecimals), usdcSymbol)
    console.log("  agg.totalAssets:  ", ethers.utils.formatUnits(aTA, usdcDecimals), usdcSymbol)
    console.log("  uni.totalAssets:  ", ethers.utils.formatUnits(uTA, usdcDecimals), usdcSymbol)

    const tokenId = await uni.positionTokenId()
    console.log("  positionTokenId:", tokenId.toString())

    console.log("\nDONE.")
}

main().catch((e) => {
    console.error(e)
    process.exit(1)
})

/*
  node scripts/save-funds-interaction/ops_runner.js --invest 0 --noRebalance --noHarvest --skipApproval
  node scripts/save-funds-interaction/ops_runner.js --invest 2000
  node scripts/save-funds-interaction/ops_runner.js --invest 2000 --force
  node scripts/save-funds-interaction/ops_runner.js --invest 2000 --staticGas 25000000
*/
