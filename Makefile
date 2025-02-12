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

install :; forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0 --no-commit && forge install OpenZeppelin/openzeppelin-foundry-upgrades@v0.3.6 --no-commit && forge install smartcontractkit/chainlink-brownie-contracts@1.3.0 --no-commit && forge install cyfrin/foundry-devops@0.2.4 --no-commit && forge install foundry-rs/forge-std@v1.9.5 --no-commit && forge install smartcontractkit/ccip@v2.17.0-ccip1.5.12 --no-commit && forge install smartcontractkit/chainlink-local@v0.2.3 --no-commit

# Update Dependencies
update:; forge update

build:; forge build

build-certora:; forge build --contracts ./certora/

test :; forge test 

coverage-report :; forge coverage --skip ReferralGatewayInvariantTest.t.sol --ir-minimum --report debug > coverage-report.txt

snapshot :; forge snapshot

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

# Protocol deployments
protoco-deploy-referral:
	@forge clean
	@forge script deploy/protocol/00-DeployReferralGateway.s.sol:DeployReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

protocol-deploy-all:
	@forge clean
	@forge script deploy/protocol/01-DeployAll.s.sol:DeployAll $(NETWORK_ARGS)

protocol-deploy-takasure:
	@forge clean
	@forge script deploy/protocol/02-DeployTakasure.s.sol:DeployTakasure $(NETWORK_ARGS)

# Protocol upgrades
protocol-upgrade-referral:
	@forge clean
	@forge script deploy/protocol/upgrades/00-UpgradeReferralGateway.s.sol:UpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

protocol-upgrade-takasure:
	@forge clean
	@forge script deploy/protocol/upgrades/01-UpgradeTakasure.s.sol:UpgradeTakasure $(NETWORK_ARGS)

# Defender
defender-prepare-upgrade:
	@forge clean
	@forge script deploy/defender/00-DefenderPrepareUpgrade.s.sol:DefenderPrepareUpgrade $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

defender-upgrade-referral:
	@forge clean
	@forge script deploy/defender/01-DefenderUpgradeReferralGateway.s.sol:DefenderUpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

# Chainlink functions
functions-deploy-bm-consumer:
	@forge script deploy/chainlink/functions/DeployBenefitMultiplierConsumer.s.sol:DeployBenefitMultiplierConsumer $(NETWORK_ARGS)

#Chainlink ccip
ccip-deploy-receiver:
	@forge clean
	@forge script deploy/chainlink/ccip/00-CcipDeployTLDCcipReceiver.s.sol:DeployTLDCcipReceiver $(NETWORK_ARGS)

ccip-deploy-sender:
	@forge clean
	@forge script deploy/chainlink/ccip/01-CcipDeployTLDCcipSender.s.sol:DeployTLDCcipSender $(NETWORK_ARGS)

ccip-upgrade-sender:
	@forge clean
	@forge script deploy/chainlink/ccip/02-CcipUpgradeTLDCcipSender.s.sol:UpgradeTLDCcipSender $(NETWORK_ARGS)

ccip-deploy-usdc-faucet:
	@forge clean
	@forge script deploy/chainlink/ccip/03-CcipDeployUsdcFaucet.s.sol:DeployUsdcFaucet $(NETWORK_ARGS)

# Interactions with ReferralGateway Contract
# Create a DAO
referral-create-dao:
	@forge script scripts/contract-interactions/referralGateway/CreateDao.s.sol:CreateDao $(NETWORK_ARGS)

# Change operator
referral-change-operator:
	@forge script scripts/contract-interactions/referralGateway/ChangeOperator.s.sol:ChangeOperator $(NETWORK_ARGS)

# Renounce admin
referral-renounce-admin:
	@forge script scripts/contract-interactions/referralGateway/ChangeAdmin.s.sol:ChangeAdmin $(NETWORK_ARGS)

# Add ccip receiver contract
referral-set-ccip-receiver:
	@forge script scripts/contract-interactions/referralGateway/SetCcipReceiverContract.s.sol:SetCcipReceiverContract $(NETWORK_ARGS)

# Interactions with BenefitMultiplierConsumer Contract
# Add a new BM Requester
functions-add-bm-requester:
	@forge script scripts/contract-interactions/bmConsumer/AddBmRequester.s.sol:AddBmRequester $(NETWORK_ARGS)

functions-request-bm:
	@forge script scripts/contract-interactions/bmConsumer/RequestBenefitMultiplier.s.sol:RequestBenefitMultiplier $(NETWORK_ARGS)

# Add a new BM fetch code
functions-add-bm-fetch-code:
	@forge script scripts/contract-interactions/bmConsumer/AddBmFetchCode.s.sol:AddBmFetchCode $(NETWORK_ARGS)

# Interactions with USDC
mock-approve-spender:
	@forge script scripts/contract-interactions/usdc/ApproveSpender.s.sol:ApproveSpender $(NETWORK_ARGS)

# Interactions with Takasure Contract
# Add a new BM Oracle Consumer
takasure-add-bm-consumer:
	@forge script scripts/contract-interactions/takasure/AddBmOracleConsumer.s.sol:AddBmOracleConsumer $(NETWORK_ARGS)

#Interactions with TLDCcipSender Contract
ccip-sender-add-usdc:
	@forge script scripts/contract-interactions/ccip/sender/AddSupportedToken.s.sol:AddSupportedToken $(NETWORK_ARGS)

#Interactions with TLDCcipReceiver Contract
ccip-receiver-add-chains:
	@forge script scripts/contract-interactions/ccip/receiver/AddAllowedChains.s.sol:AddAllowedChains $(NETWORK_ARGS)

ccip-receiver-add-senders:
	@forge script scripts/contract-interactions/ccip/receiver/AddAllowedSenders.s.sol:AddAllowedSenders $(NETWORK_ARGS)


NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring --network arb_one,$(ARGS)),--network arb_one)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ARBISCAN_API_KEY) -vvvv
else ifeq ($(findstring --network avax_mainnet,$(ARGS)),--network avax_mainnet)
	NETWORK_ARGS := --rpc-url $(AVAX_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(AVAXSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network base_mainnet,$(ARGS)),--network base_mainnet)
	NETWORK_ARGS := --rpc-url $(BASE_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv
else ifeq ($(findstring --network eth_mainnet,$(ARGS)),--network eth_mainnet)	
	NETWORK_ARGS := --rpc-url $(ETHEREUM_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network optimism_mainnet,$(ARGS)),--network optimism_mainnet)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(OPTIMISMSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network polygon_mainnet,$(ARGS)),--network polygon_mainnet)
	NETWORK_ARGS := --rpc-url $(POLYGON_MAINNET_RPC_URL) --account $(MAINNET_ACCOUNT) --sender $(MAINNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(POLYGONSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network arb_sepolia,$(ARGS)),--network arb_sepolia)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ARBISCAN_API_KEY) -vvvv
else ifeq ($(findstring --network avax_fuji,$(ARGS)),--network avax_fuji)
	NETWORK_ARGS := --rpc-url $(AVAX_TESTNET_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(AVAXSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network base_sepolia,$(ARGS)),--network base_sepolia)
	NETWORK_ARGS := --rpc-url $(BASE_TESTNET_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(BASESCAN_API_KEY) -vvvv
else ifeq ($(findstring --network eth_sepolia,$(ARGS)),--network eth_sepolia)
	NETWORK_ARGS := --rpc-url $(ETHEREUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network optimism_sepolia,$(ARGS)),--network optimism_sepolia)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_TESTNET_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(OPTIMISMSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network polygon_amoy,$(ARGS)),--network polygon_amoy)
	NETWORK_ARGS := --rpc-url $(POLYGON_TESTNET_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(POLYGONSCAN_API_KEY) -vvvv
endif

# Certora
fv:; certoraRun ./certora/conf/ReserveMathLib.conf
