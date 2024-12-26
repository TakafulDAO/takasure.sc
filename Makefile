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
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "chore: modules"

install :; forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.2 --no-commit && forge install OpenZeppelin/openzeppelin-foundry-upgrades@v0.3.1 --no-commit && forge install smartcontractkit/chainlink-brownie-contracts@1.2.0 --no-commit && forge install cyfrin/foundry-devops@0.2.2 --no-commit && forge install foundry-rs/forge-std@v1.9.1 --no-commit && forge install smartcontractkit/ccip@v2.17.0-ccip1.5.12 --no-commit && forge install smartcontractkit/chainlink-local@v0.2.3 --no-commit

# Update Dependencies
update:; forge update

build:; forge build

build-certora:; forge build --contracts ./certora/

test :; forge test 

coverage-report :; forge coverage --skip ReferralGatewayInvariantTest.t.sol --ir-minimum --report debug > coverage-report.txt

snapshot :; forge snapshot

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

deploy-referral:
	@forge clean
	@forge script deploy/00-DeployReferralGateway.s.sol:DeployReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

upgrade-referral:
	@forge clean
	@forge script deploy/01-UpgradeReferralGateway.s.sol:UpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

deploy-bm-consumer:
	@forge script deploy/02-DeployBenefitMultiplierConsumer.s.sol:DeployBenefitMultiplierConsumer $(NETWORK_ARGS)

deploy-takasure:
	@forge clean
	@forge script deploy/03-DeployTakasure.s.sol:DeployTakasure $(NETWORK_ARGS)

upgrade-takasure:
	@forge clean
	@forge script deploy/04-UpgradeTakasure.s.sol:UpgradeTakasure $(NETWORK_ARGS)

deploy-all:
	@forge clean
	@forge script deploy/05-DeployAll.s.sol:DeployAll $(NETWORK_ARGS)

upgrade-referral-defender:
	@forge clean
	@forge script deploy/06-DefenderUpgradeReferralGateway.s.sol:DefenderUpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

prepare-upgrade:
	@forge clean
	@forge script deploy/07-DefenderPrepareUpgrade.s.sol:DefenderPrepareUpgrade $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

deploy-ccip-source:
	@forge clean
	@forge script deploy/08-CcipSourceContract.s.sol:DeployTokenTransferSource $(NETWORK_ARGS)

# Interactions with ReferralGateway Contract
# Create a DAO
create-dao:
	@forge script scripts/contract-interactions/referralGateway/CreateDao.s.sol:CreateDao $(NETWORK_ARGS)

# Change operator
change-operator:
	@forge script scripts/contract-interactions/referralGateway/ChangeOperator.s.sol:ChangeOperator $(NETWORK_ARGS)

# Renounce admin
renounce-admin:
	@forge script scripts/contract-interactions/referralGateway/ChangeAdmin.s.sol:ChangeAdmin $(NETWORK_ARGS)

# Interactions with BenefitMultiplierConsumer Contract
# Add a new BM Requester
add-bm-requester:
	@forge script scripts/contract-interactions/bmConsumer/AddBmRequester.s.sol:AddBmRequester $(NETWORK_ARGS)

request-bm:
	@forge script scripts/contract-interactions/bmConsumer/RequestBenefitMultiplier.s.sol:RequestBenefitMultiplier $(NETWORK_ARGS)

# Add a new BM fetch code
add-bm-fetch-code:
	@forge script scripts/contract-interactions/bmConsumer/AddBmFetchCode.s.sol:AddBmFetchCode $(NETWORK_ARGS)

# Interactions with USDC
approve-spender:
	@forge script scripts/contract-interactions/usdc/ApproveSpender.s.sol:ApproveSpender $(NETWORK_ARGS)

# Interactions with Takasure Contract
# Add a new BM Oracle Consumer
add-bm-consumer:
	@forge script scripts/contract-interactions/takasure/AddBmOracleConsumer.s.sol:AddBmOracleConsumer $(NETWORK_ARGS)

# Join pool
join-pool:
	@forge script scripts/contract-interactions/takasure/JoinPool.s.sol:JoinPool $(NETWORK_ARGS)
	
NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring --network arb_one,$(ARGS)),--network arb_one)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ARBISCAN_API_KEY) -vvvv
else ifeq ($(findstring --network avax,$(ARGS)),--network avax)
	NETWORK_ARGS := --rpc-url $(AVAX_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(AVAXSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network base,$(ARGS)),--network base)
	NETWORK_ARGS := --rpc-url $(BASE_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv
else ifeq ($(findstring --network eth_mainnet,$(ARGS)),--network eth_mainnet)	
	NETWORK_ARGS := --rpc-url $(ETHEREUM_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network optimism,$(ARGS)),--network optimism)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(OPTIMISMSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network polygon,$(ARGS)),--network polygon)
	NETWORK_ARGS := --rpc-url $(POLYGON_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(POLYGONSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network arb_sepolia,$(ARGS)),--network arb_sepolia)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ARBISCAN_API_KEY) -vvvv
else ifeq ($(findstring --network eth_sepolia,$(ARGS)),--network eth_sepolia)
	NETWORK_ARGS := --rpc-url $(ETHEREUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
endif



# Certora
fv:; certoraRun ./certora/conf/ReserveMathLib.conf
