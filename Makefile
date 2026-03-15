###########################################################################
# =========================== REPO MANAGEMENT =========================== #
###########################################################################

-include .env

.PHONY: all test clean deploy fund help install snapshot anvil 

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
VERBOSITY_ARGS ?= -vvvv

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

install :; forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0 && forge install OpenZeppelin/openzeppelin-foundry-upgrades@v0.3.6 && forge install smartcontractkit/ccip@583f07c85a72bbd241c644e3094561d4969a4b11 && forge install smartcontractkit/chainlink-brownie-contracts@1.3.0 && forge install cyfrin/foundry-devops@0.2.4 && forge install foundry-rs/forge-std@v1.9.7 && forge install smartcontractkit/chainlink-local@v0.2.3 && forge install Uniswap/v3-core && forge install Uniswap/v3-periphery

# Update Dependencies
update:; forge update

build:; forge build

#################################################################
# =========================== TESTS =========================== #
#################################################################

build-certora:; forge build --contracts ./certora/

test :; forge test 

sim-test :; forge test --mc SaveFundInvariantTest --jobs 1

coverage-report :; forge coverage --ir-minimum --report debug > coverage-report.txt

snapshot :; forge snapshot

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

#######################################################################
# =========================== SIMULATIONS =========================== #
#######################################################################

simulate-rev-share-distribution:
	@forge clean
	@forge script scripts/simulations/rev-share-sims/RevShareMonthSimToCsv.s.sol:RevShareMonthSimToCsv -vvv

######################################################################
# =========================== MIGRATIONS =========================== #
######################################################################

# Backfill Scripts
get-revshare-pioneers :; node scripts/rev-share-backfill/01-exportRevSharePioneers.js $(ARGS)

build-revshare-allocations:
	@$(MAKE) get-revshare-pioneers ARGS="$(ARGS)"
	@node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js $(ARGS)

run-revshare-backfill-batches:
	@node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js $(ARGS)

build-backfill-execution-report:
	@$(MAKE) build-revshare-allocations ARGS="$(ARGS)"
	@node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js $(ARGS)

# ccip testnet migration
protocol-migrate-sf-ccip-usdc-arb-sepolia:
	@forge clean
	@forge script deploy/saveFunds/03-MigrateSFToCcipUSDCArbSepolia.s.sol:MigrateSFToCcipUSDCArbSepolia $(NETWORK_ARGS)

#######################################################################
# =========================== DEPLOYMENTS =========================== #
#######################################################################

# Referral gateway
protocol-deploy-referral:
	@forge clean
	@forge script deploy/protocol/referralGateway/DeployReferralGateway.s.sol:DeployReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

# Managers
protocol-deploy-address-manager:
	@forge clean
	@forge script deploy/protocol/managers/DeployAddressManager.s.sol:DeployAddressManager $(NETWORK_ARGS)
	@cp contracts/managers/AddressManager.sol contracts/version_previous_contracts/AddressManagerV1.sol

protocol-deploy-module-manager:
	@forge clean
	@forge script deploy/protocol/managers/DeployModuleManager.s.sol:DeployModuleManager $(NETWORK_ARGS)
	@cp contracts/managers/ModuleManager.sol contracts/version_previous_contracts/ModuleManagerV1.sol

# Save funds
protocol-deploy-sf-vault:
	@forge clean
	@forge script deploy/saveFunds/DeploySFVault.s.sol:DeploySFVault $(NETWORK_ARGS)
	@cp contracts/saveFunds/protocol/SFVault.sol contracts/version_previous_contracts/SFVaultV1.sol
	
protocol-deploy-sf-strat-aggregator:
	@forge clean
	@forge script deploy/saveFunds/DeploySFStrategyAggregator.s.sol:DeploySFStrategyAggregator $(NETWORK_ARGS)
	@cp contracts/saveFunds/protocol/SFStrategyAggregator.sol contracts/version_previous_contracts/SFStrategyAggregatorV1.sol

protocol-deploy-uni-v3-math:
	@forge clean
	@forge script deploy/saveFunds/DeployUniV3MathHelper.s.sol:DeployUniV3MathHelper $(NETWORK_ARGS)

protocol-deploy-sf-uni-v3-strat:
	@forge clean
	@forge script deploy/saveFunds/DeploySFUniV3Strat.s.sol:DeploySFUniV3Strat $(NETWORK_ARGS)
	@cp contracts/saveFunds/protocol/SFUniswapV3Strategy.sol contracts/version_previous_contracts/SFUniswapV3StrategyV1.sol

protocol-deploy-sf:
	@forge clean
	@forge script deploy/saveFunds/DeploySF.s.sol:DeploySF $(NETWORK_ARGS)

# ccip
ccip-deploy-receiver:
	@forge script deploy/ccip/DeploySaveInvestCCIPReceiver.s.sol:DeploySaveInvestCCIPReceiver $(NETWORK_ARGS)

ccip-deploy-sender:
	@forge clean
	@forge script deploy/ccip/DeploySaveInvestCCIPSender.s.sol:DeploySaveInvestCCIPSender $(NETWORK_ARGS)

protocol-deploy-uniswap-pool-sepolia:
	@forge script deploy/saveFunds/DeploySFUniV3PoolSepolia.s.sol:DeploySFUniV3PoolSepolia $(NETWORK_ARGS)

# ccip testnet prep
ccip-deploy-sf-usdc-testnet:
	@forge script deploy/ccip/testnetPool/00-DeploySFUSDCCcipTestnet.s.sol:DeploySFUSDCCcipTestnet $(NETWORK_ARGS)

ccip-deploy-sf-usdc-arb-sepolia-testnet:
	@forge script deploy/ccip/testnetPool/00-DeploySFUSDCCcipTestnetArbSepolia.s.sol:DeploySFUSDCCcipTestnetArbSepolia $(NETWORK_ARGS)

ccip-deploy-source-pool-testnet:
	@forge script deploy/ccip/testnetPool/01-DeployBurnMintTokenPoolSourceTestnet.s.sol:DeployBurnMintTokenPoolSourceTestnet $(NETWORK_ARGS)

ccip-deploy-dest-pool-testnet:
	@forge script deploy/ccip/testnetPool/01-DeployBurnMintTokenPoolArbSepoliaTestnet.s.sol:DeployBurnMintTokenPoolArbSepoliaTestnet $(NETWORK_ARGS)

ccip-deploy-dest-pool-testnet-legacy:
	@forge script deploy/ccip/testnetPool/01-DeploySFUSDCMintUSDCOnlyPoolArbSepolia.s.sol:DeploySFUSDCMintUSDCOnlyPoolArbSepolia $(NETWORK_ARGS)

# Modules
modules-deploy-revshare:
	@forge clean
	@forge script deploy/protocol/modules/deploys/DeployRevShareModule.s.sol:DeployRevShareModule $(NETWORK_ARGS)
	@cp contracts/modules/RevShareModule.sol contracts/version_previous_contracts/RevShareModuleV1.sol

# Tokens
tokens-deploy-nft:
	@forge clean
	@forge script deploy/tokens/nft/DeployRevShareNft.s.sol:DeployRevShareNft $(NETWORK_ARGS)
	@cp contracts/tokens/RevShareNFT.sol contracts/version_previous_contracts/RevShareNFTV1.sol

# Simulations
deploy-simulations:
	@forge clean
	@forge script scripts/simulations/save-fund-sims/DeploySFSystemArbVNet.s.sol:DeploySFSystemArbVNet $(NETWORK_ARGS)

# Automations
deploy-chainlink-upkeep:
	@forge script scripts/save-funds/interactions/DeploySaveFundsAutomationRunner.s.sol:DeploySaveFundsAutomationRunner $(NETWORK_ARGS)

deploy-chainlink-invest-upkeep:
	@forge clean
	@forge script deploy/ccipAutomation/DeploySaveFundsInvestAutomationRunner.s.sol:DeploySaveFundsInvestAutomationRunner $(NETWORK_ARGS)

####################################################################
# =========================== UPGRADES =========================== #
####################################################################

# Referral gateway
protocol-upgrade-referral:
	@forge clean
	@forge script deploy/protocol/referralGateway/UpgradeReferralGateway.s.sol:UpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

# Managers
managers-upgrade-address-manager:
	@forge clean
	@forge script deploy/protocol/managers/UpgradeAddressManager.s.sol:UpgradeAddressManager $(NETWORK_ARGS)
	@cp contracts/managers/AddressManager.sol contracts/version_previous_contracts/AddressManagerV1.sol

managers-upgrade-module-manager:
	@forge clean
	@forge script deploy/protocol/managers/UpgradeModuleManager.s.sol:UpgradeModuleManager $(NETWORK_ARGS)
	@cp contracts/managers/ModuleManager.sol contracts/version_previous_contracts/ModuleManagerV1.sol

# Modules upgrades
modules-upgrade-revshare:
	@forge clean
	@forge script deploy/protocol/modules/upgrades/UpgradeRevShareModule.s.sol:UpgradeRevShareModule $(NETWORK_ARGS)
	@cp contracts/modules/RevShareModule.sol contracts/version_previous_contracts/RevShareModuleV1.sol

# Save funds
protocol-upgrade-sf-vault:
	@forge clean
	@forge script deploy/saveFunds/04-UpgradeSFVault.s.sol:UpgradeSFVault $(NETWORK_ARGS)
	@cp contracts/saveFunds/protocol/SFVault.sol contracts/version_previous_contracts/SFVaultV1.sol

protocol-upgrade-sf-strat-aggregator:
	@forge clean
	@forge script deploy/saveFunds/05-UpgradeSFStrategyAggregator.s.sol:UpgradeSFStrategyAggregator $(NETWORK_ARGS)
	@cp contracts/saveFunds/protocol/SFStrategyAggregator.sol contracts/version_previous_contracts/SFStrategyAggregatorV1.sol

protocol-upgrade-sf-uni-v3-strat:
	@forge clean
	@forge script deploy/saveFunds/06-UpgradeSFUniswapV3Strategy.s.sol:UpgradeSFUniswapV3Strategy $(NETWORK_ARGS)
	@cp contracts/saveFunds/protocol/SFUniswapV3Strategy.sol contracts/version_previous_contracts/SFUniswapV3StrategyV1.sol

# Tokens
tokens-upgrade-nft:
	@forge clean
	@forge script deploy/tokens/nft/UpgradeRevShareNft.s.sol:UpgradeRevShareNFT $(NETWORK_ARGS)
	@cp contracts/tokens/RevShareNFT.sol contracts/version_previous_contracts/RevShareNFTV1.sol

# ccip
ccip-upgrade-sender:
	@forge clean
	@forge script deploy/ccip/UpgradeSaveInvestCCIPSender.s.sol:UpgradeSaveInvestCCIPSender $(NETWORK_ARGS)

# Automations
upgrade-chainlink-invest-upkeep:
	@forge clean
	@forge script deploy/ccipAutomation/UpgradeSaveFundsInvestAutomationRunner.s.sol:UpgradeSaveFundsInvestAutomationRunner $(NETWORK_ARGS)

##########################################################################
# =========================== UPGRADES PREPS =========================== #
##########################################################################

# Referral gateway
protocol-prepare-upgrade-referral:
	@forge clean
	@forge script deploy/protocol/referralGateway/PrepareReferralUpgrade.s.sol:PrepareReferralUpgrade $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

# Managers
protocol-prepare-upgrade-module-manager:
	@forge clean
	@forge script deploy/protocol/managers/PrepareModuleManagerUpgrade.s.sol:PrepareModuleManagerUpgrade $(NETWORK_ARGS)
	@cp contracts/managers/ModuleManager.sol contracts/version_previous_contracts/ModuleManagerV1.sol

protocol-prepare-upgrade-address-manager:
	@forge clean
	@forge script deploy/protocol/managers/PrepareAddressManagerUpgrade.s.sol:PrepareAddressManagerUpgrade $(NETWORK_ARGS)
	@cp contracts/managers/AddressManager.sol contracts/version_previous_contracts/AddressManagerV1.sol

# Modules
protocol-prepare-upgrade-revshare:
	@forge clean
	@forge script deploy/protocol/modules/preps/PrepareRevShareModuleUpgrade.s.sol:PrepareRevShareModuleUpgrade $(NETWORK_ARGS)
	@cp contracts/modules/RevShareModule.sol contracts/version_previous_contracts/RevShareModuleV1.sol

# ccip
protocol-prepare-upgrade-ccip-sender:
	@forge clean
	@forge script deploy/ccip/PrepareSaveInvestCCIPSenderUpgrade.s.sol:PrepareSaveInvestCCIPSenderUpgrade $(NETWORK_ARGS)

# Automations
prepare-chainlink-invest-upkeep-upgrade:
	@forge clean
	@forge script deploy/ccipAutomation/PrepareSaveFundsInvestAutomationRunnerUpgrade.s.sol:PrepareSaveFundsInvestAutomationRunnerUpgrade $(NETWORK_ARGS)

########################################################################
# =========================== INTERACTIONS =========================== #
########################################################################

ccip-source-pool-grant-roles-testnet:
	@forge script deploy/ccip/testnetPool/02-GrantSourcePoolMintBurnRoles.s.sol:GrantSourcePoolMintBurnRoles $(NETWORK_ARGS)

ccip-register-source-pool-testnet:
	@forge script deploy/ccip/testnetPool/03-RegisterAndSetPoolSelfServe.s.sol:RegisterAndSetPoolSelfServe $(NETWORK_ARGS)

ccip-configure-pool-lane-testnet:
	@forge script deploy/ccip/testnetPool/05-ConfigureCcipPoolLanes.s.sol:ConfigureCcipPoolLanes $(NETWORK_ARGS)

ccip-allowlist-senders:
	@forge script scripts/contract-interactions/ccip/AllowlistCcipSenders.s.sol:AllowlistCcipSenders $(NETWORK_ARGS)

ccip-test-send-message:
	@forge script scripts/contract-interactions/ccip/TestSendSaveInvestCcipMessage.s.sol:TestSendSaveInvestCcipMessage $(NETWORK_ARGS)

# Interactions with USDC
mock-approve-spender:
	@forge script scripts/contract-interactions/usdc/ApproveSpender.s.sol:ApproveSpender $(NETWORK_ARGS)

# Prepare roles in sepolia
addr-mgr-prepare-roles:
	@forge script scripts/contract-interactions/managers/CreateAndAcceptRoles.s.sol:CreateAndAcceptRoles $(NETWORK_ARGS)

# Add addressess in sepolia
addr-mgr-add-addresses:
	@forge script scripts/contract-interactions/managers/AddAddresses.s.sol:AddAddresses $(NETWORK_ARGS)

config-strat:
	@forge script scripts/contract-interactions/saveFunds/ConfigStrat.s.sol:ConfigStrat $(NETWORK_ARGS)

invest-into-strat:
	@forge script scripts/contract-interactions/saveFunds/InvestIntoStrategy.s.sol:InvestIntoStrategy $(NETWORK_ARGS)

####################################################################
# =========================== NETWORKS =========================== #
####################################################################

NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring --network arb_one,$(ARGS)),--network arb_one)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_MAINNET_RPC_URL) --trezor --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network avax_mainnet,$(ARGS)),--network avax_mainnet)
	NETWORK_ARGS := --rpc-url $(AVALANCHE_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network base_mainnet,$(ARGS)),--network base_mainnet)
	NETWORK_ARGS := --rpc-url $(BASE_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network eth_mainnet,$(ARGS)),--network eth_mainnet)	
	NETWORK_ARGS := --rpc-url $(ETHEREUM_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network optimism_mainnet,$(ARGS)),--network optimism_mainnet)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network polygon_mainnet,$(ARGS)),--network polygon_mainnet)
	NETWORK_ARGS := --rpc-url $(POLYGON_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network arb_sepolia,$(ARGS)),--network arb_sepolia)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network base_sepolia,$(ARGS)),--network base_sepolia)
	NETWORK_ARGS := --rpc-url $(BASE_TESTNET_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network eth_sepolia,$(ARGS)),--network eth_sepolia)
	NETWORK_ARGS := --rpc-url $(ETHEREUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
else ifeq ($(findstring --network optimism_sepolia,$(ARGS)),--network optimism_sepolia)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_TESTNET_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) $(VERBOSITY_ARGS)
endif

# Certora
fv:; certoraRun ./certora/conf/ReserveMathLib.conf
