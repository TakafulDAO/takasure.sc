-include .env

.PHONY: all test clean deploy fund help install snapshot anvil 

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

help:
	@echo "Usage:"
	@echo "  make deploy [ARGS=...]\n    example: make deploy ARGS=\"--network arb_sepolia\""
	@echo ""
	@echo "  make fund [ARGS=...]\n    example: make deploy ARGS=\"--network arb_sepolia\""

all: clean remove install update build

# Clean the repo
clean  :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.2 --no-commit && forge install OpenZeppelin/openzeppelin-foundry-upgrades@v0.3.1 --no-commit && forge install smartcontractkit/chainlink-brownie-contracts@1.2.0 --no-commit && forge install cyfrin/foundry-devops@0.2.2 --no-commit && forge install foundry-rs/forge-std@v1.9.1 --no-commit 

# Update Dependencies
update:; forge update

build:; forge build

build-certora:; forge build --contracts ./certora/

test :; forge test 

coverage :; forge coverage --report debug > coverage-report.txt

snapshot :; forge snapshot

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

deploy-bm-consumer:
	@forge script deploy/01-DeployBenefitMultiplierConsumer.s.sol:DeployBenefitMultiplierConsumer $(NETWORK_ARGS)

deploy-takasure:
	@forge clean
	@forge script deploy/02-DeployTokenAndPool.s.sol:DeployTokenAndPool $(NETWORK_ARGS)

# Interactions with BenefitMultiplierConsumer Contract
# Add a new BM Requester
add-bm-requester:
	@forge script scripts/contract-interactions/bmConsumer/AddBmRequester.s.sol:AddBmRequester $(NETWORK_ARGS)

# Add a new BM fetch code
add-bm-fetch-code:
	@forge script scripts/contract-interactions/bmConsumer/AddBmFetchCode.s.sol:AddBmFetchCode $(NETWORK_ARGS)

# Interactions with Takasure Contract
# Add a new BM Oracle Consumer
add-bm-consumer:
	@forge script scripts/contract-interactions/takasure/AddBmOracleConsumer.s.sol:AddBmOracleConsumer $(NETWORK_ARGS)

NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring --network arb_sepolia,$(ARGS)),--network arb_sepolia)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_TESTNET_SEPOLIA_RPC_URL) --account $(ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ARBISCAN_API_KEY) -vvvv
endif

# Certora
fv:; certoraRun ./certora/conf/ReserveMathLib.conf
