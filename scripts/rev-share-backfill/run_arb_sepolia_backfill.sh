#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

CHAIN_ID="421614"
CHAIN_FLAG="arb-sep"
DEPLOYMENTS_DIR="$REPO_ROOT/deployments/testnet_arbitrum_sepolia"
OUTPUT_DIR="$REPO_ROOT/scripts/rev-share-backfill/output/testnet"

ADDRESS_MANAGER_JSON="$DEPLOYMENTS_DIR/AddressManager.json"
MODULE_MANAGER_JSON="$DEPLOYMENTS_DIR/ModuleManager.json"
REVSHARE_MODULE_JSON="$DEPLOYMENTS_DIR/RevShareModule.json"
REVSHARE_NFT_JSON="$DEPLOYMENTS_DIR/RevShareNft.json"
USDC_JSON="$DEPLOYMENTS_DIR/USDC.json"

PROTOCOL_TYPE_ADMIN="0"
PROTOCOL_TYPE_MODULE="2"
PROTOCOL_TYPE_PROTOCOL="3"

TOTAL_STEPS=11
SKIP_DEPLOY=0
REVIEW_ONLY=0

step() {
    local number="$1"
    local title="$2"
    echo ""
    echo "================================================================"
    echo "Step ${number}/${TOTAL_STEPS}: ${title}"
    echo "================================================================"
}

info() {
    echo ">>> $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-deploy)
                SKIP_DEPLOY=1
                shift
                ;;
            --review-only)
                REVIEW_ONLY=1
                SKIP_DEPLOY=1
                shift
                ;;
            --help)
                echo "Usage: bash scripts/rev-share-backfill/run_arb_sepolia_backfill.sh [--skip-deploy] [--review-only]"
                echo ""
                echo "--skip-deploy  Reuse ModuleManager and RevShareModule from the Sepolia deployment JSON files"
                echo "--review-only  Read-only check run: reuse current deployments and skip state-changing onchain steps"
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                echo "Try: bash scripts/rev-share-backfill/run_arb_sepolia_backfill.sh --help" >&2
                exit 1
                ;;
        esac
    done
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $command_name" >&2
        exit 1
    fi
}

require_file() {
    local file_path="$1"
    if [[ ! -f "$file_path" ]]; then
        echo "ERROR: Required file not found: $file_path" >&2
        exit 1
    fi
}

load_env() {
    require_file "$ENV_FILE"
    info "Loading environment from $ENV_FILE"
    set -a
    source <(sed 's/\r$//' "$ENV_FILE")
    set +a
}

require_env() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        echo "ERROR: Environment variable $var_name is required." >&2
        exit 1
    fi
}

json_address() {
    local file_path="$1"

    node - "$file_path" <<'NODE'
const fs = require("fs")

const filePath = process.argv[2]
const json = JSON.parse(fs.readFileSync(filePath, "utf8"))
const address = json.address

if (typeof address !== "string" || !/^0x[a-fA-F0-9]{40}$/.test(address)) {
    process.exit(1)
}

process.stdout.write(address)
NODE
}

update_deployment_json_address() {
    local file_path="$1"
    local address="$2"

    node - "$file_path" "$address" <<'NODE'
const fs = require("fs")

const [filePath, address] = process.argv.slice(2)
const json = JSON.parse(fs.readFileSync(filePath, "utf8"))
json.address = address
fs.writeFileSync(filePath, `${JSON.stringify(json, null, 2)}\n`, "utf8")
NODE
}

read_broadcast_address() {
    local broadcast_path="$1"

    node - "$broadcast_path" <<'NODE'
const fs = require("fs")

const filePath = process.argv[2]
const run = JSON.parse(fs.readFileSync(filePath, "utf8"))

if (run.returns && typeof run.returns === "object") {
    for (const key of Object.keys(run.returns)) {
        const value = run.returns[key] && run.returns[key].value
        if (typeof value === "string" && /^0x[a-fA-F0-9]{40}$/.test(value)) {
            process.stdout.write(value)
            process.exit(0)
        }
    }
}

if (Array.isArray(run.transactions)) {
    for (let i = run.transactions.length - 1; i >= 0; i -= 1) {
        const tx = run.transactions[i]
        if (typeof tx.contractAddress === "string" && /^0x[a-fA-F0-9]{40}$/.test(tx.contractAddress)) {
            process.stdout.write(tx.contractAddress)
            process.exit(0)
        }
    }
}

process.exit(1)
NODE
}

get_protocol_address() {
    local address_manager="$1"
    local name="$2"

    node - "$ADDRESS_MANAGER_JSON" "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" "$address_manager" "$name" <<'NODE'
const fs = require("fs")
const { ethers } = require("ethers")

async function main() {
    const [deploymentPath, rpcUrl, addressManagerAddress, name] = process.argv.slice(2)
    const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"))
    const provider = new ethers.providers.JsonRpcProvider(rpcUrl)
    const contract = new ethers.Contract(addressManagerAddress, deployment.abi, provider)

    try {
        const protocolAddress = await contract.getProtocolAddressByName(name)
        const addr = protocolAddress.addr || protocolAddress[1]
        process.stdout.write(ethers.utils.getAddress(addr))
    } catch (error) {
        process.stdout.write("")
    }
}

main().catch((error) => {
    console.error(error.message || String(error))
    process.exit(1)
})
NODE
}

ensure_protocol_address() {
    local address_manager="$1"
    local name="$2"
    local expected_address="$3"
    local address_type="$4"

    local current_address
    current_address="$(get_protocol_address "$address_manager" "$name")"

    if [[ -z "$current_address" ]]; then
        info "$name is missing in AddressManager. Adding it."
        cast send "$address_manager" \
            "addProtocolAddress(string,address,uint8)" \
            "$name" \
            "$expected_address" \
            "$address_type" \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT"
        return
    fi

    if [[ "${current_address,,}" == "${expected_address,,}" ]]; then
        info "$name already points to $current_address"
        return
    fi

    info "$name currently points to $current_address. Updating it to $expected_address."
    cast send "$address_manager" \
        "updateProtocolAddress(string,address)" \
        "$name" \
        "$expected_address" \
        --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
        --account "$TESTNET_ACCOUNT"
}

assert_protocol_address() {
    local address_manager="$1"
    local name="$2"
    local expected_address="$3"

    local current_address
    current_address="$(get_protocol_address "$address_manager" "$name")"

    if [[ -z "$current_address" ]]; then
        echo "ERROR: $name is missing in AddressManager." >&2
        exit 1
    fi

    if [[ "${current_address,,}" != "${expected_address,,}" ]]; then
        echo "ERROR: $name points to $current_address, expected $expected_address." >&2
        exit 1
    fi

    info "$name verified at $current_address"
}

read_total_backfill_raw() {
    local allocations_json="$1"

    node - "$allocations_json" <<'NODE'
const fs = require("fs")

const filePath = process.argv[2]
const json = JSON.parse(fs.readFileSync(filePath, "utf8"))
if (!json.totalBackfillRaw) {
    process.exit(1)
}
process.stdout.write(String(json.totalBackfillRaw))
NODE
}

main() {
    parse_args "$@"

    require_command node
    require_command forge
    require_command cast
    require_command bash
    require_command sed

    load_env

    require_env TESTNET_SUBGRAPH_URL
    require_env ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    require_env TESTNET_DEPLOYER_ADDRESS

    if [[ "$REVIEW_ONLY" != "1" ]]; then
        require_env TESTNET_ACCOUNT
        require_env TESTNET_PK
    fi

    require_file "$ADDRESS_MANAGER_JSON"
    require_file "$MODULE_MANAGER_JSON"
    require_file "$REVSHARE_MODULE_JSON"
    require_file "$REVSHARE_NFT_JSON"
    require_file "$USDC_JSON"

    cd "$REPO_ROOT"

    local address_manager
    local revshare_nft
    local contribution_token
    local module_manager
    local revshare_module
    local total_backfill_raw

    address_manager="$(json_address "$ADDRESS_MANAGER_JSON")"
    revshare_nft="$(json_address "$REVSHARE_NFT_JSON")"
    contribution_token="$(json_address "$USDC_JSON")"

    if [[ "$REVIEW_ONLY" == "1" ]]; then
        info "Review-only mode enabled."
        info "This reuses the current Sepolia ModuleManager and RevShareModule deployment JSON addresses."
        info "No state-changing onchain calls will be sent."
        info "The script will refresh local outputs and verify the configured addresses it can read."
    elif [[ "$SKIP_DEPLOY" == "1" ]]; then
        info "Skip deploy mode enabled."
        info "This reuses the current Sepolia ModuleManager and RevShareModule deployment JSON addresses."
        info "It also skips the deployment-address writes into AddressManager."
        info "Funding and backfill execution still run later in the flow."
    fi

    step 1 "Export current pioneers from the Sepolia subgraph"
    node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain "$CHAIN_FLAG"

    step 2 "Deploy ModuleManager on Arbitrum Sepolia"
    if [[ "$SKIP_DEPLOY" == "1" ]]; then
        module_manager="$(json_address "$MODULE_MANAGER_JSON")"
        info "Skipping deployment. Reusing ModuleManager at $module_manager"
    else
        forge script deploy/protocol/managers/DeployModuleManager.s.sol:DeployModuleManager \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT" \
            --sender "$TESTNET_DEPLOYER_ADDRESS" \
            --broadcast \
            -vvvv

        module_manager="$(read_broadcast_address "$REPO_ROOT/broadcast/DeployModuleManager.s.sol/$CHAIN_ID/run-latest.json")"
        update_deployment_json_address "$MODULE_MANAGER_JSON" "$module_manager"
        info "ModuleManager deployed at $module_manager"
        info "Updated $MODULE_MANAGER_JSON"
    fi

    step 3 "Deploy RevShareModule on Arbitrum Sepolia"
    if [[ "$SKIP_DEPLOY" == "1" ]]; then
        revshare_module="$(json_address "$REVSHARE_MODULE_JSON")"
        info "Skipping deployment. Reusing RevShareModule at $revshare_module"
    else
        forge script deploy/protocol/modules/deploys/DeployRevShareModule.s.sol:DeployRevShareModule \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT" \
            --sender "$TESTNET_DEPLOYER_ADDRESS" \
            --broadcast \
            -vvvv

        revshare_module="$(read_broadcast_address "$REPO_ROOT/broadcast/DeployRevShareModule.s.sol/$CHAIN_ID/run-latest.json")"
        update_deployment_json_address "$REVSHARE_MODULE_JSON" "$revshare_module"
        info "RevShareModule deployed at $revshare_module"
        info "Updated $REVSHARE_MODULE_JSON"
    fi

    step 4 "Ensure ADMIN__REVENUE_RECEIVER is configured in AddressManager"
    if [[ "$REVIEW_ONLY" == "1" ]]; then
        assert_protocol_address \
            "$address_manager" \
            "ADMIN__REVENUE_RECEIVER" \
            "$TESTNET_DEPLOYER_ADDRESS"
    else
        ensure_protocol_address \
            "$address_manager" \
            "ADMIN__REVENUE_RECEIVER" \
            "$TESTNET_DEPLOYER_ADDRESS" \
            "$PROTOCOL_TYPE_ADMIN"
    fi

    step 5 "Build the RevShare backfill allocations"
    node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain "$CHAIN_FLAG"

    step 6 "Review the calculated backfill total"
    total_backfill_raw="$(read_total_backfill_raw "$OUTPUT_DIR/allocations/revshare_backfill_allocations.json")"
    info "totalBackfillRaw = $total_backfill_raw"

    step 7 "Wire AddressManager entries for the Sepolia flow"
    if [[ "$REVIEW_ONLY" == "1" ]]; then
        info "Review-only mode: verifying the reused deployment-address wiring."
        assert_protocol_address \
            "$address_manager" \
            "PROTOCOL__MODULE_MANAGER" \
            "$module_manager"
        assert_protocol_address \
            "$address_manager" \
            "PROTOCOL__CONTRIBUTION_TOKEN" \
            "$contribution_token"
        assert_protocol_address \
            "$address_manager" \
            "PROTOCOL__REVSHARE_NFT" \
            "$revshare_nft"
        assert_protocol_address \
            "$address_manager" \
            "MODULE__REVSHARE" \
            "$revshare_module"
    elif [[ "$SKIP_DEPLOY" == "1" ]]; then
        info "Skipping deployment-address wiring because --skip-deploy is enabled."
        info "Expected reused addresses:"
        info "PROTOCOL__MODULE_MANAGER -> $module_manager"
        info "PROTOCOL__CONTRIBUTION_TOKEN -> $contribution_token"
        info "PROTOCOL__REVSHARE_NFT -> $revshare_nft"
        info "MODULE__REVSHARE -> $revshare_module"
    else
        info "Checking PROTOCOL__CONTRIBUTION_TOKEN and PROTOCOL__REVSHARE_NFT before writing them."
        ensure_protocol_address \
            "$address_manager" \
            "PROTOCOL__MODULE_MANAGER" \
            "$module_manager" \
            "$PROTOCOL_TYPE_PROTOCOL"
        ensure_protocol_address \
            "$address_manager" \
            "PROTOCOL__CONTRIBUTION_TOKEN" \
            "$contribution_token" \
            "$PROTOCOL_TYPE_PROTOCOL"
        ensure_protocol_address \
            "$address_manager" \
            "PROTOCOL__REVSHARE_NFT" \
            "$revshare_nft" \
            "$PROTOCOL_TYPE_PROTOCOL"
        ensure_protocol_address \
            "$address_manager" \
            "MODULE__REVSHARE" \
            "$revshare_module" \
            "$PROTOCOL_TYPE_MODULE"
    fi

    step 8 "Point RevShareNFT to AddressManager"
    if [[ "$REVIEW_ONLY" == "1" ]]; then
        info "Review-only mode: skipping RevShareNFT.setAddressManager(address)."
        info "This script does not verify that value because RevShareNFT has no public getter for it."
    else
        cast send "$revshare_nft" \
            "setAddressManager(address)" \
            "$address_manager" \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT"
    fi

    step 9 "Mint Sepolia USDC-like tokens and fund RevShareModule"
    if [[ "$REVIEW_ONLY" == "1" ]]; then
        info "Review-only mode: skipping mint, approve, and depositNoStream."
        info "Computed totalBackfillRaw remains $total_backfill_raw"
    else
        cast send "$contribution_token" \
            "mintUSDC(address,uint256)" \
            "$TESTNET_DEPLOYER_ADDRESS" \
            "$total_backfill_raw" \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT"

        cast send "$contribution_token" \
            "approve(address,uint256)" \
            "$revshare_module" \
            "$total_backfill_raw" \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT"

        cast send "$revshare_module" \
            "depositNoStream(uint256)" \
            "$total_backfill_raw" \
            --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
            --account "$TESTNET_ACCOUNT"
    fi

    step 10 "Execute the backfill batches on Sepolia"
    if [[ "$REVIEW_ONLY" == "1" ]]; then
        info "Review-only mode: skipping onchain backfill execution."
        info "You can inspect the prepared allocations at $OUTPUT_DIR/allocations/revshare_backfill_allocations.json"
    else
        node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain "$CHAIN_FLAG"
    fi

    step 11 "Done"
    info "Pioneers snapshot: $OUTPUT_DIR/pioneers/revshare_pioneers.json"
    info "Allocations output: $OUTPUT_DIR/allocations/revshare_backfill_allocations.json"
    info "Execution report: $OUTPUT_DIR/execution/revshare_backfill_execution_report.json"
    if [[ "$REVIEW_ONLY" == "1" ]]; then
        info "Sepolia rev-share review flow completed."
    else
        info "Sepolia rev-share backfill flow completed."
    fi
}

main "$@"
