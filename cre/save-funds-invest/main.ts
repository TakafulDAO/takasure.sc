import { Runner } from "@chainlink/cre-sdk"
import { configSchema, initWorkflow } from "./workflow"

export async function main() {
  // The CRE runner loads the workflow config from `workflow.yaml` / `config.production.json`
  // and then bootstraps the cron-driven workflow defined in `workflow.ts`.
  const runner = await Runner.newRunner({ configSchema })
  await runner.run(initWorkflow)
}

main()
