#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

CHAIN_ID="421614"
CHAIN_FLAG="arb-sep"
NETWORK_ARGS="--network arb_sepolia"
DEPLOYMENTS_DIR="$REPO_ROOT/deployments/testnet_arbitrum_sepolia"
OUTPUT_DIR="$REPO_ROOT/scripts/rev-share-backfill/output/testnet"
PIONEERS_SOURCE_CHAIN_FLAG="$CHAIN_FLAG"
PIONEERS_SOURCE_SCOPE="testnet"
PIONEERS_SOURCE_LABEL="Arbitrum Sepolia"
PIONEERS_SOURCE_ENV_VAR="TESTNET_SUBGRAPH_URL"
PIONEERS_OUTPUT_DIR="$OUTPUT_DIR"
START_TS=""

ADDRESS_MANAGER_JSON="$DEPLOYMENTS_DIR/AddressManager.json"
MODULE_MANAGER_JSON="$DEPLOYMENTS_DIR/ModuleManager.json"
REVSHARE_MODULE_JSON="$DEPLOYMENTS_DIR/RevShareModule.json"
REVSHARE_NFT_JSON="$DEPLOYMENTS_DIR/RevShareNft.json"
USDC_JSON="$DEPLOYMENTS_DIR/USDC.json"

PROTOCOL_TYPE_ADMIN="0"
PROTOCOL_TYPE_MODULE="2"
PROTOCOL_TYPE_PROTOCOL="3"

TOTAL_STEPS=12
VERIFY_SAMPLE_SIZE="${BACKFILL_VERIFY_SAMPLE_SIZE:-5}"

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
    if [[ $# -eq 0 ]]; then
        return
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                echo "Usage: bash scripts/rev-share-backfill/run_arb_sepolia_backfill.sh [--pioneers-source arb-one|arb-sep] [--start-ts <unix>]"
                echo ""
                echo "Runs the full repeatable Arbitrum Sepolia rev-share backfill flow."
                echo "Each run redeploys ModuleManager and RevShareModule, rewrites their Sepolia deployment JSON files,"
                echo "updates the module-related AddressManager entries, and only creates the token/NFT entries if missing."
                echo ""
                echo "Flags:"
                echo "  --pioneers-source <arb-one|arb-sep>  Select whether the pioneer snapshot comes from mainnet or Sepolia."
                echo "                                      Execution still happens on Arbitrum Sepolia."
                echo "  --start-ts <unix>                  Override the allocation backfill start timestamp passed to script 02."
                exit 0
                ;;
            --pioneers-source)
                if [[ $# -lt 2 ]]; then
                    echo "ERROR: Missing value for --pioneers-source. Expected arb-one or arb-sep." >&2
                    exit 1
                fi

                case "$2" in
                    arb-one)
                        PIONEERS_SOURCE_CHAIN_FLAG="arb-one"
                        PIONEERS_SOURCE_SCOPE="mainnet"
                        PIONEERS_SOURCE_LABEL="Arbitrum One"
                        PIONEERS_SOURCE_ENV_VAR="MAINNET_SUBGRAPH_URL"
                        PIONEERS_OUTPUT_DIR="$REPO_ROOT/scripts/rev-share-backfill/output/mainnet"
                        ;;
                    arb-sep)
                        PIONEERS_SOURCE_CHAIN_FLAG="arb-sep"
                        PIONEERS_SOURCE_SCOPE="testnet"
                        PIONEERS_SOURCE_LABEL="Arbitrum Sepolia"
                        PIONEERS_SOURCE_ENV_VAR="TESTNET_SUBGRAPH_URL"
                        PIONEERS_OUTPUT_DIR="$OUTPUT_DIR"
                        ;;
                    *)
                        echo "ERROR: Invalid value for --pioneers-source: $2. Expected arb-one or arb-sep." >&2
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --start-ts)
                if [[ $# -lt 2 ]]; then
                    echo "ERROR: Missing value for --start-ts. Expected a Unix timestamp." >&2
                    exit 1
                fi

                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: Invalid value for --start-ts: $2. Expected a Unix timestamp." >&2
                    exit 1
                fi

                START_TS="$2"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown argument(s): $*" >&2
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

ensure_protocol_address_if_missing() {
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
        info "$name already exists at $current_address"
        return
    fi

    info "$name already exists at $current_address. Leaving it unchanged."
}

add_protocol_address() {
    local address_manager="$1"
    local name="$2"
    local expected_address="$3"
    local address_type="$4"

    info "Adding $name -> $expected_address"
    cast send "$address_manager" \
        "addProtocolAddress(string,address,uint8)" \
        "$name" \
        "$expected_address" \
        "$address_type" \
        --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
        --account "$TESTNET_ACCOUNT"
}

delete_protocol_address_if_present() {
    local address_manager="$1"
    local name="$2"

    local current_address
    current_address="$(get_protocol_address "$address_manager" "$name")"

    if [[ -z "$current_address" ]]; then
        info "$name is not set. Nothing to delete."
        return
    fi

    info "Deleting $name -> $current_address"
    cast send "$address_manager" \
        "deleteProtocolAddress(address)" \
        "$current_address" \
        --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
        --account "$TESTNET_ACCOUNT"
}

get_module_state() {
    local module_manager="$1"
    local module_address="$2"

    local module_state
    module_state="$(cast call "$module_manager" \
        "getModuleState(address)(uint8)" \
        "$module_address" \
        --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL")"
    module_state="${module_state//$'\r'/}"
    module_state="${module_state//$'\n'/}"
    module_state="${module_state%% *}"

    printf "%s" "$module_state"
}

read_previous_module_manager_from_broadcast_history() {
    local current_module_manager="$1"

    node - "$REPO_ROOT/broadcast/DeployModuleManager.s.sol/$CHAIN_ID" "$current_module_manager" <<'NODE'
const fs = require("fs")
const path = require("path")

const [dirPath, currentAddressRaw] = process.argv.slice(2)
const currentAddress = String(currentAddressRaw || "").toLowerCase()

function readProxyAddress(run) {
    if (run?.returns?.proxy?.value && /^0x[a-fA-F0-9]{40}$/.test(run.returns.proxy.value)) {
        return run.returns.proxy.value
    }

    if (Array.isArray(run?.transactions)) {
        for (let i = run.transactions.length - 1; i >= 0; i -= 1) {
            const tx = run.transactions[i]
            if (typeof tx.contractAddress === "string" && /^0x[a-fA-F0-9]{40}$/.test(tx.contractAddress)) {
                return tx.contractAddress
            }
        }
    }

    return null
}

const files = fs.readdirSync(dirPath)
    .filter((name) => /^run-\d+\.json$/.test(name))
    .map((name) => {
        const filePath = path.join(dirPath, name)
        const run = JSON.parse(fs.readFileSync(filePath, "utf8"))
        return {
            name,
            timestamp: Number(run.timestamp || 0),
            address: readProxyAddress(run),
        }
    })
    .filter((entry) => entry.address)
    .sort((a, b) => b.timestamp - a.timestamp)

const currentIndex = files.findIndex((entry) => entry.address.toLowerCase() === currentAddress)

if (currentIndex !== -1) {
    const previousEntry = files[currentIndex + 1]
    if (previousEntry) {
        process.stdout.write(previousEntry.address)
        process.exit(0)
    }
}

for (const entry of files) {
    if (entry.address.toLowerCase() !== currentAddress) {
        process.stdout.write(entry.address)
        process.exit(0)
    }
}

process.exit(1)
NODE
}

prepare_module_migration() {
    local address_manager="$1"
    local current_module_manager="$2"
    local current_revshare_module="$3"
    local new_module_manager="$4"

    local current_state
    current_state="$(get_module_state "$current_module_manager" "$current_revshare_module")"

    if [[ "$current_state" != "0" && "$current_state" != "4" ]]; then
        return
    fi

    local previous_module_manager=""
    previous_module_manager="$(read_previous_module_manager_from_broadcast_history "$current_module_manager" || true)"

    if [[ -n "$previous_module_manager" ]]; then
        info "Current PROTOCOL__MODULE_MANAGER does not track the current MODULE__REVSHARE. Repointing temporarily to previous ModuleManager $previous_module_manager so the old module can be deprecated cleanly."
        ensure_protocol_address \
            "$address_manager" \
            "PROTOCOL__MODULE_MANAGER" \
            "$previous_module_manager" \
            "$PROTOCOL_TYPE_PROTOCOL"

        current_module_manager="$previous_module_manager"
        current_state="$(get_module_state "$current_module_manager" "$current_revshare_module")"
    fi

    if [[ "$current_state" == "0" || "$current_state" == "4" ]]; then
        echo "ERROR: Current MODULE__REVSHARE $current_revshare_module is not active in PROTOCOL__MODULE_MANAGER $current_module_manager (state=$current_state)." >&2
        echo "Fix the AddressManager/ModuleManager state first, then rerun this script." >&2
        exit 1
    fi
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

read_verification_sample() {
    local allocations_json="$1"
    local sample_size="$2"

    node - "$allocations_json" "$sample_size" <<'NODE'
const fs = require("fs")

const [filePath, sampleSizeRaw] = process.argv.slice(2)
const sampleSize = Number(sampleSizeRaw)
const json = JSON.parse(fs.readFileSync(filePath, "utf8"))
const allocations = Array.isArray(json.allocations) ? json.allocations : []

if (!Number.isInteger(sampleSize) || sampleSize <= 0) {
    throw new Error(`Invalid sample size: ${sampleSizeRaw}`)
}

for (const allocation of allocations.slice(0, sampleSize)) {
    process.stdout.write(`${allocation.address},${allocation.amountRaw}\n`)
}
NODE
}

verify_backfill_sample() {
    local allocations_json="$1"
    local revshare_module="$2"
    local rpc_url="$3"
    local sample_size="$4"

    local verified_count=0

    while IFS=, read -r account expected_amount; do
        [[ -z "${account:-}" ]] && continue

        local actual_amount
        actual_amount="$(cast call "$revshare_module" \
            "revenuePerAccount(address)(uint256)" \
            "$account" \
            --rpc-url "$rpc_url")"
        actual_amount="${actual_amount//$'\r'/}"
        actual_amount="${actual_amount//$'\n'/}"
        actual_amount="${actual_amount%% *}"

        if [[ "$actual_amount" != "$expected_amount" ]]; then
            echo "ERROR: Backfill verification failed for $account. Expected $expected_amount, got $actual_amount." >&2
            exit 1
        fi

        info "Verified $account -> $actual_amount raw"
        verified_count=$((verified_count + 1))
    done < <(read_verification_sample "$allocations_json" "$sample_size")

    if [[ "$verified_count" -eq 0 ]]; then
        echo "ERROR: No allocations found to verify in $allocations_json" >&2
        exit 1
    fi

    info "Verified $verified_count allocation(s) against revenuePerAccount(address)."
}

main() {
    parse_args "$@"

    require_command node
    require_command make
    require_command forge
    require_command cast
    require_command bash
    require_command sed

    load_env

    require_env "$PIONEERS_SOURCE_ENV_VAR"
    require_env ARBITRUM_TESTNET_SEPOLIA_RPC_URL
    require_env TESTNET_DEPLOYER_ADDRESS
    require_env TESTNET_ACCOUNT
    require_env TESTNET_PK

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
    local allocations_json

    address_manager="$(json_address "$ADDRESS_MANAGER_JSON")"
    revshare_nft="$(json_address "$REVSHARE_NFT_JSON")"
    contribution_token="$(json_address "$USDC_JSON")"
    allocations_json="$OUTPUT_DIR/allocations/revshare_backfill_allocations.json"

    step 1 "Export current pioneers from the $PIONEERS_SOURCE_LABEL subgraph"
    node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain "$PIONEERS_SOURCE_CHAIN_FLAG"

    step 2 "Deploy ModuleManager on Arbitrum Sepolia"
    make protocol-deploy-module-manager ARGS="$NETWORK_ARGS" VERBOSITY_ARGS=""

    module_manager="$(read_broadcast_address "$REPO_ROOT/broadcast/DeployModuleManager.s.sol/$CHAIN_ID/run-latest.json")"
    update_deployment_json_address "$MODULE_MANAGER_JSON" "$module_manager"
    info "ModuleManager deployed at $module_manager"
    info "Updated $MODULE_MANAGER_JSON"

    step 3 "Deploy RevShareModule on Arbitrum Sepolia"
    make modules-deploy-revshare ARGS="$NETWORK_ARGS" VERBOSITY_ARGS=""

    revshare_module="$(read_broadcast_address "$REPO_ROOT/broadcast/DeployRevShareModule.s.sol/$CHAIN_ID/run-latest.json")"
    update_deployment_json_address "$REVSHARE_MODULE_JSON" "$revshare_module"
    info "RevShareModule deployed at $revshare_module"
    info "Updated $REVSHARE_MODULE_JSON"

    step 4 "Build the pioneers-only RevShare backfill allocations"
    local allocation_args=(
        --chain "$CHAIN_FLAG"
        --pioneers-chain "$PIONEERS_SOURCE_CHAIN_FLAG"
        --test
    )
    if [[ -n "$START_TS" ]]; then
        allocation_args+=(--start-ts "$START_TS")
        info "Using explicit backfill start timestamp override: $START_TS"
    fi

    node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js \
        "${allocation_args[@]}"

    step 5 "Review the calculated backfill total"
    total_backfill_raw="$(read_total_backfill_raw "$allocations_json")"
    info "totalBackfillRaw = $total_backfill_raw"

    step 6 "Wire AddressManager entries for the Sepolia flow"
    info "Refreshing the module-related entries and only creating the token/NFT entries if missing."
    ensure_protocol_address_if_missing \
        "$address_manager" \
        "PROTOCOL__CONTRIBUTION_TOKEN" \
        "$contribution_token" \
        "$PROTOCOL_TYPE_PROTOCOL"
    ensure_protocol_address_if_missing \
        "$address_manager" \
        "PROTOCOL__REVSHARE_NFT" \
        "$revshare_nft" \
        "$PROTOCOL_TYPE_PROTOCOL"

    local current_module_manager
    local current_revshare_module
    current_module_manager="$(get_protocol_address "$address_manager" "PROTOCOL__MODULE_MANAGER")"
    current_revshare_module="$(get_protocol_address "$address_manager" "MODULE__REVSHARE")"

    if [[ -n "$current_revshare_module" ]]; then
        if [[ -z "$current_module_manager" ]]; then
            echo "ERROR: MODULE__REVSHARE exists but PROTOCOL__MODULE_MANAGER is missing. Fix AddressManager first." >&2
            exit 1
        fi

        prepare_module_migration \
            "$address_manager" \
            "$current_module_manager" \
            "$current_revshare_module" \
            "$module_manager"

        info "Removing the current MODULE__REVSHARE before switching to the newly deployed ModuleManager."
        delete_protocol_address_if_present "$address_manager" "MODULE__REVSHARE"
    else
        info "MODULE__REVSHARE is missing. A fresh add will be used after PROTOCOL__MODULE_MANAGER is set."
    fi

    ensure_protocol_address \
        "$address_manager" \
        "PROTOCOL__MODULE_MANAGER" \
        "$module_manager" \
        "$PROTOCOL_TYPE_PROTOCOL"

    if [[ -z "$(get_protocol_address "$address_manager" "MODULE__REVSHARE")" ]]; then
        add_protocol_address \
            "$address_manager" \
            "MODULE__REVSHARE" \
            "$revshare_module" \
            "$PROTOCOL_TYPE_MODULE"
    else
        ensure_protocol_address \
            "$address_manager" \
            "MODULE__REVSHARE" \
            "$revshare_module" \
            "$PROTOCOL_TYPE_MODULE"
    fi

    step 7 "Ensure ADMIN__REVENUE_RECEIVER is configured for future claim or stream rehearsal"
    ensure_protocol_address \
        "$address_manager" \
        "ADMIN__REVENUE_RECEIVER" \
        "$TESTNET_DEPLOYER_ADDRESS" \
        "$PROTOCOL_TYPE_ADMIN"

    step 8 "Point RevShareNFT to AddressManager"
    cast send "$revshare_nft" \
        "setAddressManager(address)" \
        "$address_manager" \
        --rpc-url "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
        --account "$TESTNET_ACCOUNT"

    step 9 "Mint Sepolia USDC-like tokens and fund RevShareModule"
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

    step 10 "Execute the backfill batches on Sepolia"
    node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain "$CHAIN_FLAG"

    step 11 "Verify sample backfilled balances onchain"
    info "Checking the first $VERIFY_SAMPLE_SIZE pioneers-only allocation(s) from $allocations_json"
    verify_backfill_sample \
        "$allocations_json" \
        "$revshare_module" \
        "$ARBITRUM_TESTNET_SEPOLIA_RPC_URL" \
        "$VERIFY_SAMPLE_SIZE"

    step 12 "Done"
    info "Pioneers snapshot: $PIONEERS_OUTPUT_DIR/pioneers/revshare_pioneers.json"
    info "Allocations output: $OUTPUT_DIR/allocations/revshare_backfill_allocations.json"
    info "Execution report: $OUTPUT_DIR/execution/revshare_backfill_execution_report.json"
    info "Sepolia rev-share backfill flow completed."
}

main "$@"
