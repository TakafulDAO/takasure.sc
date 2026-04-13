const { BigNumber, utils } = require("ethers")

const STRATEGY_EVENTS = new utils.Interface([
    "event OnPositionCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1)",
    "event OnPositionMinted(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0, uint256 amount1)",
    "event OnPositionRebalanced(uint256 indexed oldTokenId, uint256 indexed newTokenId, int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper)",
    "event OnSwapExecuted(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut)",
])

const ADDR = {
    strategy: "0x2e9db0a46ab897d0e1e08cca9157d06b61f8112e",
    vault: "0x42eFc18C181CBDa3108E95c7080E8B9564dCD86a",
    pool: "0x51dff4A270295C78CA668c3B6a8b427269AeaA7f",
    underlying: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    other: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9",
    positionManager: "0xC36442b4a4522E871399CD717aBDD847Ab11FE88",
}

function makeProvider(timestamp) {
    return {
        async getBlock() {
            return { timestamp }
        },
    }
}

function makePreState(overrides = {}) {
    const timestamp = overrides.timestamp || 1715000000
    return {
        provider: makeProvider(timestamp),
        chainName: "arb-one",
        strategyAddress: ADDR.strategy,
        vaultAddress: ADDR.vault,
        poolAddress: ADDR.pool,
        underlyingAddress: ADDR.underlying,
        otherAddress: ADDR.other,
        token0Address: ADDR.underlying,
        token1Address: ADDR.other,
        underlyingSymbol: "USDC",
        otherSymbol: "USDT",
        underlyingDecimals: 6,
        otherDecimals: 6,
        underlyingBalance: BigNumber.from(0),
        otherBalance: BigNumber.from(0),
        positionTokenId: BigNumber.from("5402605"),
        tickLower: -720,
        tickUpper: 480,
        ...overrides,
    }
}

function encodeStrategyEvents(events) {
    return events.map((event, index) => {
        const fragment = STRATEGY_EVENTS.getEvent(event.name)
        const encoded = STRATEGY_EVENTS.encodeEventLog(fragment, event.args)
        return {
            address: ADDR.strategy,
            topics: encoded.topics,
            data: encoded.data,
            logIndex: index,
        }
    })
}

function makeSimulation({ events = [], assetChanges = [], timestamp = 1715000000, blockNumber = 123456 }) {
    const logs = encodeStrategyEvents(events)
    return {
        transaction: {
            logs,
            timestamp,
            block_number: blockNumber,
            transaction_info: {
                asset_changes: assetChanges,
            },
        },
        logs,
        assetChanges,
        timestamp,
        blockNumber,
        publicUrl: "https://tenderly.co/public/example",
        dashboardUrl: "https://dashboard.tenderly.co/simulator/example",
    }
}

function erc20Transfer(contractAddress, symbol, from, to, rawAmount) {
    return {
        type: "Transfer",
        from,
        to,
        raw_amount: String(rawAmount),
        token_info: {
            standard: "ERC20",
            contract_address: contractAddress,
            symbol,
        },
    }
}

function erc721Change(type, from, to) {
    return {
        type,
        from,
        to,
        raw_amount: "1",
        token_info: {
            standard: "ERC721",
            contract_address: ADDR.positionManager,
            symbol: "UNI-V3-POS",
        },
    }
}

function buildBundleData({ strategies, payloads }) {
    return utils.defaultAbiCoder.encode(["address[]", "bytes[]"], [strategies, payloads])
}

function buildRebalancePayload({
    tickLower,
    tickUpper,
    encoding = "new",
    actionDataProvided = true,
    pmDeadlineRaw = "0",
}) {
    if (encoding === "legacy") {
        return utils.defaultAbiCoder.encode(
            ["int24", "int24", "uint256", "uint256", "uint256"],
            [tickLower, tickUpper, pmDeadlineRaw, 0, 0],
        )
    }

    const actionData = actionDataProvided
        ? utils.defaultAbiCoder.encode(
              ["uint16", "bytes", "bytes", "uint256", "uint256", "uint256"],
              [7000, "0x1234", "0x5678", pmDeadlineRaw, 0, 0],
          )
        : "0x"
    return utils.defaultAbiCoder.encode(["int24", "int24", "bytes"], [tickLower, tickUpper, actionData])
}

const happyPath = {
    preState: makePreState({
        currentPositionUnderlying: BigNumber.from("13334850"),
        currentPositionOther: BigNumber.from("2414890"),
    }),
    decodedPlan: {
        strategyAddress: ADDR.strategy,
        payload: "0x01",
        encoding: "new",
        actionDataProvided: true,
        newTickLower: -594,
        newTickUpper: 606,
        pmDeadlineRaw: BigNumber.from(0),
        minUnderlying: BigNumber.from(0),
        minOther: BigNumber.from(0),
        otherRatioBps: BigNumber.from(7000),
        swapToOtherData: "0x1234",
        swapToUnderlyingData: "0x5678",
    },
    simulation: makeSimulation({
        events: [
            {
                name: "OnPositionCollected",
                args: ["5402605", "16003786", "0"],
            },
            {
                name: "OnSwapExecuted",
                args: [ADDR.underlying, ADDR.other, "7622603", "7618317"],
            },
            {
                name: "OnPositionMinted",
                args: ["5417305", -594, 606, "100000", "8381183", "7541439"],
            },
            {
                name: "OnPositionRebalanced",
                args: ["5402605", "5417305", -720, 480, -594, 606],
            },
        ],
        assetChanges: [
            erc20Transfer(ADDR.underlying, "USDC", ADDR.pool, ADDR.strategy, "16003786"),
            erc721Change("Burn", ADDR.vault, null),
            erc20Transfer(ADDR.underlying, "USDC", ADDR.strategy, ADDR.pool, "7622603"),
            erc20Transfer(ADDR.other, "USDT", ADDR.pool, ADDR.strategy, "7618317"),
            erc20Transfer(ADDR.underlying, "USDC", ADDR.strategy, ADDR.pool, "8381183"),
            erc20Transfer(ADDR.other, "USDT", ADDR.strategy, ADDR.pool, "7541439"),
            erc721Change("Mint", null, ADDR.vault),
        ],
    }),
    safeResult: {
        safeTxHash: "0xabc123",
        queueUrl: `https://app.safe.global/transactions/queue?safe=arb1:${ADDR.vault}`,
        txServiceUrl: "https://safe-transaction-arbitrum.safe.global/api/v1",
        txServiceTransactionUrl:
            "https://safe-transaction-arbitrum.safe.global/api/v1/multisig-transactions/0xabc123/",
    },
}

const noSwap = {
    preState: makePreState(),
    decodedPlan: {
        strategyAddress: ADDR.strategy,
        payload: "0x02",
        encoding: "legacy",
        actionDataProvided: false,
        newTickLower: -600,
        newTickUpper: 600,
        pmDeadlineRaw: BigNumber.from(1715000900),
        minUnderlying: BigNumber.from(0),
        minOther: BigNumber.from(0),
        otherRatioBps: BigNumber.from(0),
        swapToOtherData: "0x",
        swapToUnderlyingData: "0x",
    },
    simulation: makeSimulation({
        events: [
            {
                name: "OnPositionCollected",
                args: ["5402605", "5000000", "5000000"],
            },
            {
                name: "OnPositionMinted",
                args: ["5410000", -600, 600, "100000", "5000000", "5000000"],
            },
            {
                name: "OnPositionRebalanced",
                args: ["5402605", "5410000", -720, 480, -600, 600],
            },
        ],
        assetChanges: [
            erc20Transfer(ADDR.underlying, "USDC", ADDR.pool, ADDR.strategy, "5000000"),
            erc20Transfer(ADDR.other, "USDT", ADDR.pool, ADDR.strategy, "5000000"),
            erc20Transfer(ADDR.underlying, "USDC", ADDR.strategy, ADDR.pool, "5000000"),
            erc20Transfer(ADDR.other, "USDT", ADDR.strategy, ADDR.pool, "5000000"),
            erc721Change("Mint", null, ADDR.vault),
        ],
    }),
}

const noPosition = {
    preState: makePreState({
        positionTokenId: BigNumber.from(0),
        tickLower: -720,
        tickUpper: 480,
    }),
    decodedPlan: {
        strategyAddress: ADDR.strategy,
        payload: "0x03",
        encoding: "new",
        actionDataProvided: true,
        newTickLower: -480,
        newTickUpper: 480,
        pmDeadlineRaw: BigNumber.from(0),
        minUnderlying: BigNumber.from(0),
        minOther: BigNumber.from(0),
        otherRatioBps: BigNumber.from(0),
        swapToOtherData: "0x",
        swapToUnderlyingData: "0x",
    },
    simulation: makeSimulation({
        events: [],
        assetChanges: [],
    }),
}

const sweepOnly = {
    preState: makePreState(),
    decodedPlan: {
        strategyAddress: ADDR.strategy,
        payload: "0x04",
        encoding: "legacy",
        actionDataProvided: false,
        newTickLower: -540,
        newTickUpper: 540,
        pmDeadlineRaw: BigNumber.from(1715000800),
        minUnderlying: BigNumber.from(0),
        minOther: BigNumber.from(0),
        otherRatioBps: BigNumber.from(0),
        swapToOtherData: "0x",
        swapToUnderlyingData: "0x",
    },
    simulation: makeSimulation({
        events: [
            {
                name: "OnPositionCollected",
                args: ["5402605", "10000000", "0"],
            },
            {
                name: "OnPositionMinted",
                args: ["5411111", -540, 540, "100000", "9000000", "0"],
            },
            {
                name: "OnPositionRebalanced",
                args: ["5402605", "5411111", -720, 480, -540, 540],
            },
        ],
        assetChanges: [
            erc20Transfer(ADDR.underlying, "USDC", ADDR.pool, ADDR.strategy, "10000000"),
            erc20Transfer(ADDR.underlying, "USDC", ADDR.strategy, ADDR.pool, "9000000"),
            erc721Change("Mint", null, ADDR.vault),
            erc20Transfer(ADDR.underlying, "USDC", ADDR.strategy, ADDR.vault, "1000000"),
        ],
    }),
}

module.exports = {
    ADDR,
    buildBundleData,
    buildRebalancePayload,
    happyPath,
    noPosition,
    noSwap,
    sweepOnly,
}
