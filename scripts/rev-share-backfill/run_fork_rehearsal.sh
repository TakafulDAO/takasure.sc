#!/usr/bin/env bash
set -euo pipefail

########################################
#             CONFIG
########################################

# Project root
ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts/rev-share-backfill"

SCRIPT_01="$SCRIPTS_DIR/01-exportRevSharePioneers.js"
SCRIPT_02="$SCRIPTS_DIR/02-buildRevShareBackfillAllocations.js"
SCRIPT_03="$SCRIPTS_DIR/03-buildRevShareSafeBatchJson.js"
SCRIPT_04="$SCRIPTS_DIR/04-buildRevShareBackfillCalldata.js"

ALLOCATIONS_JSON="$SCRIPTS_DIR/output/allocations/revshare_backfill_allocations.json"
CALLDATA_JSON="$SCRIPTS_DIR/output/calldata/revshare_backfill_calldata.json"

# Upstream Arbitrum RPC (real mainnet, used only for forking)
: "${ARBITRUM_MAINNET_RPC_URL:?ARBITRUM_MAINNET_RPC_URL is required}"

# Fork config
# If FORK_BLOCK is empty or unset, we fork at latest.
FORK_BLOCK="${FORK_BLOCK:-}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
LOCAL_RPC="http://127.0.0.1:${ANVIL_PORT}"
CHAIN_ID="${CHAIN_ID:-42161}"

# Start anvil automatically (1=yes, 0=no)
START_ANVIL="${START_ANVIL:-1}"

# Deploy contracts automatically on the fork (1=yes, 0=no)
DEPLOY_CONTRACTS="${DEPLOY_CONTRACTS:-1}"

# SEND the adminBackfillRevenue txs (1=yes, 0=no)
EXECUTE_ON_RPC="${EXECUTE_ON_RPC:-0}"

# RPC to execute backfill on (by default local anvil)
BACKFILL_EXECUTE_RPC="${BACKFILL_EXECUTE_RPC:-$LOCAL_RPC}"

# Private key used to deploy & to send adminBackfillRevenue (must have OPERATOR role there)
# Use one of the anvil keys if testing locally (shown in anvil logs)
: "${DEPLOYER_KEY:=}"           # required if DEPLOY_CONTRACTS=1 or EXECUTE_ON_RPC=1
: "${BACKFILL_OPERATOR_KEY:=$DEPLOYER_KEY}"  # default: same as deployer

########################################
#          SANITY / DEPENDENCIES
########################################

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is not in PATH. Please install it." >&2
    exit 1
  fi
}

need anvil
need forge
need cast
need node
need jq

mkdir -p \
  "$SCRIPTS_DIR/output/pioneers" \
  "$SCRIPTS_DIR/output/allocations" \
  "$SCRIPTS_DIR/output/safe" \
  "$SCRIPTS_DIR/output/calldata"

########################################
#            START ANVIL FORK
########################################

ANVIL_PID=""

if [ "$START_ANVIL" = "1" ]; then
  if [ -n "$FORK_BLOCK" ]; then
    echo ">>> Starting anvil fork of Arbitrum at block $FORK_BLOCK ..."
    anvil \
      --fork-url "$ARBITRUM_MAINNET_RPC_URL" \
      --fork-block-number "$FORK_BLOCK" \
      --chain-id "$CHAIN_ID" \
      --port "$ANVIL_PORT" \
      > "$SCRIPTS_DIR/anvil-revshare.log" 2>&1 &
  else
    echo ">>> Starting anvil fork of Arbitrum at latest block ..."
    anvil \
      --fork-url "$ARBITRUM_MAINNET_RPC_URL" \
      --chain-id "$CHAIN_ID" \
      --port "$ANVIL_PORT" \
      > "$SCRIPTS_DIR/anvil-revshare.log" 2>&1 &
  fi

  ANVIL_PID=$!
  echo "Anvil PID = $ANVIL_PID (logs: $SCRIPTS_DIR/anvil-revshare.log)"

  cleanup() {
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
      echo ">>> Stopping anvil (pid $ANVIL_PID)..."
      kill "$ANVIL_PID" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  echo ">>> Waiting for anvil to become ready ..."
  until cast block-number --rpc-url "$LOCAL_RPC" >/dev/null 2>&1; do
    sleep 1
  done
  echo ">>> Anvil fork is up at $LOCAL_RPC"
else
  echo ">>> START_ANVIL=0, skipping anvil. Using existing node at $BACKFILL_EXECUTE_RPC (if EXECUTE_ON_RPC=1)."
fi

########################################
#    DEPLOY MANAGERS + REVSHARE MODULE
########################################

if [ "$DEPLOY_CONTRACTS" = "1" ]; then
  if [ -z "$DEPLOYER_KEY" ]; then
    echo "ERROR: DEPLOY_CONTRACTS=1 but DEPLOYER_KEY is not set." >&2
    exit 1
  fi

  echo ">>> Deploying AddressManager, ModuleManager & RevShareModule to fork..."
  forge script scripts/rev-share-backfill/Deployments.s.sol:Deployments \
    --rpc-url "$LOCAL_RPC" \
    --broadcast \
    --private-key "$DEPLOYER_KEY" \
    -vvv

  DEPLOY_BROADCAST="$ROOT_DIR/broadcast/Deployements.s.sol/$CHAIN_ID/run-latest.json"
  if [ ! -f "$DEPLOY_BROADCAST" ]; then
    echo "ERROR: Deployments broadcast file not found at $DEPLOY_BROADCAST" >&2
    exit 1
  fi

  ADDRESS_MANAGER_ADDRESS=$(
    jq -r '.transactions[] | select(.contractName=="AddressManager") | .contractAddress' \
      "$DEPLOY_BROADCAST" | tail -n 1
  )
  MODULE_MANAGER_ADDRESS=$(
    jq -r '.transactions[] | select(.contractName=="ModuleManager") | .contractAddress' \
      "$DEPLOY_BROADCAST" | tail -n 1
  )
  REVSHARE_MODULE_ADDRESS=$(
    jq -r '.transactions[] | select(.contractName=="RevShareModule") | .contractAddress' \
      "$DEPLOY_BROADCAST" | tail -n 1
  )

  echo ">>> AddressManager deployed at: $ADDRESS_MANAGER_ADDRESS"
  echo ">>> ModuleManager  deployed at: $MODULE_MANAGER_ADDRESS"
  echo ">>> RevShareModule deployed at: $REVSHARE_MODULE_ADDRESS"

  if [ -z "$ADDRESS_MANAGER_ADDRESS" ] || [ "$ADDRESS_MANAGER_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
    echo "ERROR: Failed to parse AddressManager address from broadcast" >&2
    exit 1
  fi
  if [ -z "$REVSHARE_MODULE_ADDRESS" ] || [ "$REVSHARE_MODULE_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
    echo "ERROR: Failed to parse RevShareModule address from broadcast" >&2
    exit 1
  fi

  export ADDRESS_MANAGER_ADDRESS
  export REVSHARE_MODULE_ADDRESS
else
  echo ">>> DEPLOY_CONTRACTS=0, skipping contract deployment."
fi

########################################
#   RUN OFF-CHAIN ALLOCATION SCRIPTS
########################################

echo ">>> Step 1: export pioneers from subgraph"
node "$SCRIPT_01"

echo ">>> Step 2: build time-weighted backfill allocations"
# For script 02 we want to talk to the FORKED chain (AddressManager there)
ARBITRUM_MAINNET_RPC_URL="$LOCAL_RPC" node "$SCRIPT_02"

echo ">>> Step 3: build Safe batch JSON"
# Requires SAFE_ADDRESS and SAFE_CHAIN_ID/BACKFILL_BATCH_SIZE in env/.env
node "$SCRIPT_03"

echo ">>> Step 4: build calldata batches JSON/CSV"
node "$SCRIPT_04"

if [ ! -f "$CALLDATA_JSON" ]; then
  echo "ERROR: $CALLDATA_JSON not found; something went wrong in step 4." >&2
  exit 1
fi

echo ">>> Off-chain pipeline completed."
echo "    Allocations: $ALLOCATIONS_JSON"
echo "    Calldata    : $CALLDATA_JSON"

########################################
#   OPTIONAL: EXECUTE BATCHES ON A NODE
########################################

if [ "$EXECUTE_ON_RPC" = "1" ]; then
  if [ -z "$BACKFILL_OPERATOR_KEY" ]; then
    echo "ERROR: EXECUTE_ON_RPC=1 but BACKFILL_OPERATOR_KEY is not set." >&2
    exit 1
  fi

  echo ">>> EXECUTE_ON_RPC=1, sending batches to $BACKFILL_EXECUTE_RPC"
  echo ">>> NOTE: REVSHARE_MODULE_ADDRESS=$REVSHARE_MODULE_ADDRESS"
  echo "          BACKFILL_OPERATOR_KEY must have OPERATOR role on that RevShareModule."

  TOTAL_BATCHES=$(jq '.totalBatches' "$CALLDATA_JSON")
  REVSHARE_MODULE=$(jq -r '.revShareModule' "$CALLDATA_JSON")

  echo ">>> Total batches: $TOTAL_BATCHES"
  echo ">>> RevShareModule (from JSON): $REVSHARE_MODULE"

  for ((i=0; i< TOTAL_BATCHES; i++)); do
    TO=$(jq -r ".batches[$i].to" "$CALLDATA_JSON")
    DATA=$(jq -r ".batches[$i].calldata" "$CALLDATA_JSON")
    NUM_ADDR=$(jq -r ".batches[$i].numAddresses" "$CALLDATA_JSON")
    SUM_TOKENS=$(jq -r ".batches[$i].sumTokens" "$CALLDATA_JSON")

    echo ">>> Sending batch $i → $TO (addresses: $NUM_ADDR, ~${SUM_TOKENS} tokens)"

    cast send "$TO" \
      --data "$DATA" \
      --rpc-url "$BACKFILL_EXECUTE_RPC" \
      --private-key "$BACKFILL_OPERATOR_KEY" \
      --legacy \
      -vvv
  done

  echo ">>> All batches sent."
else
  echo ">>> EXECUTE_ON_RPC=0, not sending any transactions."
  echo "    You can now inspect $CALLDATA_JSON or use revshare_backfill_safe_batch.json in Safe."
fi

echo ">>> Done."
