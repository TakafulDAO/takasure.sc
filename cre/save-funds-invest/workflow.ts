import {
  bytesToHex,
  cre,
  encodeCallMsg,
  getNetwork,
  LAST_FINALIZED_BLOCK_NUMBER,
  prepareReportRequest,
  TxStatus,
  type CronPayload,
  type Runtime,
} from "@chainlink/cre-sdk"
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  parseAbi,
  parseAbiParameters,
  zeroAddress,
  type Address,
  type Hex,
} from "viem"
import { z } from "zod"

const runnerAbi = parseAbi([
  "function checkUpkeep(bytes) external view returns (bool, bytes)",
])

export const configSchema = z.object({
  schedule: z.string(),
  evm: z.object({
    chainSelectorName: z.string(),
    runnerAddress: z.string(),
    receiverAddress: z.string(),
    gasLimit: z.string().optional(),
  }),
})

type Config = z.infer<typeof configSchema>

function resolveNetwork(config: Config) {
  // The workflow only reads and writes on Arbitrum, but CRE still needs Ethereum mainnet
  // in `project.yaml` because workflow deployment is registered there.
  const network = getNetwork({
    chainFamily: "evm",
    chainSelectorName: config.evm.chainSelectorName,
    isTestnet: false,
  })

  if (!network) {
    throw new Error(`Network not found: ${config.evm.chainSelectorName}`)
  }

  return network
}

function readCheckUpkeep(
  runtime: Runtime<Config>,
  client: InstanceType<typeof cre.capabilities.EVMClient>,
  runnerAddress: Address,
) {
  // The CRE workflow mirrors the old keeper read step by calling `checkUpkeep("")`
  // before it ever attempts an onchain write through the receiver.
  const callData = encodeFunctionData({
    abi: runnerAbi,
    functionName: "checkUpkeep",
    args: ["0x"],
  })

  const result = client.callContract(runtime, {
    call: encodeCallMsg({ from: zeroAddress, to: runnerAddress, data: callData }),
    blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
  }).result()

  return decodeFunctionResult({
    abi: runnerAbi,
    functionName: "checkUpkeep",
    data: bytesToHex(result.data),
  }) as readonly [boolean, Hex]
}

function buildReportPayload(triggerOutput: CronPayload, performData: Hex): Hex {
  const scheduledExecutionTime = triggerOutput.scheduledExecutionTime

  if (!scheduledExecutionTime) {
    throw new Error("Cron trigger payload is missing scheduledExecutionTime")
  }

  // The scheduled execution timestamp is the safest replay-protection nonce available to the
  // workflow because it is unique per cron firing and does not depend on mutable contract state.
  return encodeAbiParameters(
    parseAbiParameters("uint256 scheduledExecutionTimeSeconds, uint32 scheduledExecutionTimeNanos, bytes performData"),
    [scheduledExecutionTime.seconds, scheduledExecutionTime.nanos, performData],
  )
}

export const onCronTrigger = (runtime: Runtime<Config>, triggerOutput: CronPayload): string => {
  const network = resolveNetwork(runtime.config)
  const client = new cre.capabilities.EVMClient(network.chainSelector.selector)
  const runnerAddress = runtime.config.evm.runnerAddress as Address
  const receiverAddress = runtime.config.evm.receiverAddress as Address

  // This is the offchain read gate. If the runner says no upkeep is needed, the workflow
  // exits without spending gas on a receiver write.
  const [upkeepNeeded, performData] = readCheckUpkeep(runtime, client, runnerAddress)
  runtime.log(`checkUpkeep returned: ${upkeepNeeded}`)

  if (!upkeepNeeded) {
    runtime.log("No upkeep needed. Skipping execution.")
    return "Skipped: no upkeep needed"
  }

  // The receiver replays on exact `(metadata, report)` pairs, so the report payload
  // includes the cron trigger timestamp instead of using a constant empty payload.
  // `performData` is included for observability and future-proofing even though the current
  // runner ignores caller-supplied bytes and re-reads execution state during `performUpkeep`.
  const reportPayload = buildReportPayload(triggerOutput, performData)

  // CRE signs the report and then asks the chain-specific KeystoneForwarder to deliver it
  // to `SaveFundsInvestCREReceiver.onReport(...)`.
  const report = runtime.report(prepareReportRequest(reportPayload)).result()
  const writeResult = client.writeReport(runtime, {
    receiver: receiverAddress,
    report,
    gasConfig: runtime.config.evm.gasLimit ? { gasLimit: runtime.config.evm.gasLimit } : undefined,
  }).result()

  // A successful CRE write needs both a successful transaction and a successful receiver
  // execution. We check both so the workflow fails loudly when the receiver rejects a report.
  if (writeResult.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`Receiver write failed: ${writeResult.errorMessage || writeResult.txStatus}`)
  }

  if (
    writeResult.receiverContractExecutionStatus !== undefined &&
    writeResult.receiverContractExecutionStatus !== 0
  ) {
    throw new Error(
      `Receiver contract execution failed: status ${writeResult.receiverContractExecutionStatus}`,
    )
  }

  const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
  runtime.log(`Receiver write succeeded. TX: ${txHash}`)

  return `Executed: ${txHash}`
}

export function initWorkflow(config: Config) {
  const cronTrigger = new cre.capabilities.CronCapability()

  return [
    // One cron workflow is enough for this migration:
    // cron -> checkUpkeep -> if true write report -> receiver -> performUpkeep.
    cre.handler(
      cronTrigger.trigger({ schedule: config.schedule }),
      onCronTrigger,
    ),
  ]
}
