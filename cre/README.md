# Takasure CRE Workflows

This folder contains Chainlink CRE workflow code and configuration.

Current workflow:

- `save-funds-invest`

Quick start:

```bash
cd cre/save-funds-invest
yarn install
```

Simulate from the repo root:

```bash
cre -R ./cre workflow simulate save-funds-invest -T production-settings
```

Deploy once CRE access is enabled:

```bash
cre -R ./cre workflow deploy save-funds-invest -T production-settings
```

Important notes:

- `cre/project.yaml` reads `ETHEREUM_MAINNET_RPC_URL` and `ARBITRUM_MAINNET_RPC_URL` from
  `cre/.env`.
- `cre/.env.example` is included as a template for new environments.
- The production workflow should poll more frequently than `runner.interval`; the current
  production config polls hourly while the runner still enforces the actual 12-hour onchain gate.
- Review `workflow-name` before deploying.
