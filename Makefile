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

install :; forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.1.0 && forge install OpenZeppelin/openzeppelin-foundry-upgrades@v0.3.6 && forge install smartcontractkit/ccip@583f07c85a72bbd241c644e3094561d4969a4b11 && forge install smartcontractkit/chainlink-brownie-contracts@1.3.0 && forge install cyfrin/foundry-devops@0.2.4 && forge install foundry-rs/forge-std@v1.9.7 && forge install smartcontractkit/chainlink-local@v0.2.3 && forge install Uniswap/v3-core && forge install Uniswap/v3-periphery

# Update Dependencies
update:; forge update

build:; forge build

build-certora:; forge build --contracts ./certora/

test :; forge test 

coverage-report :; forge coverage --ir-minimum --report debug > coverage-report.txt

snapshot :; forge snapshot

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

# Simulations
simulate-rev-share-distribution:
	@forge script scripts/simulations/RevShareMonthSimToCsv.s.sol:RevShareMonthSimToCsv -vvv
	
# Protocol deployments
protocol-deploy-referral:
	@forge clean
	@forge script deploy/protocol/00-DeployReferralGateway.s.sol:DeployReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

protocol-deploy-address-manager:
	@forge clean
	@forge script deploy/protocol/managers/DeployAddressManager.s.sol:DeployAddressManager $(NETWORK_ARGS)
	@cp contracts/managers/AddressManager.sol contracts/version_previous_contracts/AddressManagerV1.sol

protocol-deploy-sf-vault:
	@forge clean
	@forge script deploy/saveFunds/DeploySFVault.s.sol:DeploySFVault $(NETWORK_ARGS)
	@cp contracts/saveFunds/SFVault.sol contracts/version_previous_contracts/SFVaultV1.sol
	
protocol-deploy-sf-strat-aggregator:
	@forge clean
	@forge script deploy/saveFunds/DeploySFStrategyAggregator.s.sol:DeploySFStrategyAggregator $(NETWORK_ARGS)
	@cp contracts/saveFunds/SFStrategyAggregator.sol contracts/version_previous_contracts/SFStrategyAggregatorV1.sol

protocol-deploy-uni-v3-math:
	@forge clean
	@forge script deploy/saveFunds/DeployUniV3MathHelper.s.sol:DeployUniV3MathHelper $(NETWORK_ARGS)

protocol-deploy-sf-uni-v3-strat:
	@forge clean
	@forge script deploy/saveFunds/DeploySFUniV3Strat.s.sol:DeploySFUniV3Strat $(NETWORK_ARGS)
	@cp contracts/saveFunds/SFUniswapV3Strategy.sol contracts/version_previous_contracts/SFUniswapV3StrategyV1.sol

protocol-deploy-sf:
	@forge clean
	@forge script deploy/saveFunds/DeploySF.s.sol:DeploySF $(NETWORK_ARGS)

protocol-migrate-sf-ccip-usdc-arb-sepolia:
	@forge clean
	@forge script deploy/saveFunds/03-MigrateSFToCcipUSDCArbSepolia.s.sol:MigrateSFToCcipUSDCArbSepolia $(NETWORK_ARGS)

protocol-deploy-uniswap-pool-sepolia:
	@forge script deploy/saveFunds/DeploySFUniV3PoolSepolia.s.sol:DeploySFUniV3PoolSepolia $(NETWORK_ARGS)

# Protocol upgrades
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

protocol-upgrade-referral:
	@forge clean
	@forge script deploy/protocol/upgrades/00-UpgradeReferralGateway.s.sol:UpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

protocol-check-upgrade-referral:
	@forge clean
	@forge script deploy/protocol/upgrades/01-CheckReferralUpgrade.s.sol:CheckReferralUpgrade $(NETWORK_ARGS)

protocol-prepare-upgrade-referral:
	@forge clean
	@forge script deploy/protocol/upgrades/02-PrepareReferralUpgrade.s.sol:PrepareReferralUpgrade $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

# Token deployments
tokens-deploy-nft:
	@forge clean
	@forge script deploy/tokens/nft/DeployRevShareNft.s.sol:DeployRevShareNft $(NETWORK_ARGS)
	@cp contracts/tokens/nft/RevShareNFT.sol contracts/version_previous_contracts/RevShareNFTV1.sol

# Token upgrades
tokens-upgrade-nft:
	@forge clean
	@forge script deploy/tokens/nft/UpgradeRevShareNFT.s.sol:UpgradeRevShareNFT $(NETWORK_ARGS)
	@cp contracts/tokens/RevShareNFT.sol contracts/version_previous_contracts/RevShareNFTV1.sol

# CCIP deployments
ccip-deploy-receiver:
	@forge script deploy/ccip/00-DeploySaveInvestCCIPReceiver.s.sol:DeploySaveInvestCCIPReceiver $(NETWORK_ARGS)

ccip-deploy-sender:
	@forge clean
	@forge script deploy/ccip/01-DeploySaveInvestCCIPSender.s.sol:DeploySaveInvestCCIPSender $(NETWORK_ARGS)

# CCIP upgrades
ccip-upgrade-sender:
	@forge clean
	@forge script deploy/ccip/02-UpgrapdeSaveInvestCCIPSender.s.sol:UpgrapdeSaveInvestCCIPSender $(NETWORK_ARGS)

# CCIP testnet prep
ccip-deploy-sf-usdc-testnet:
	@forge script deploy/ccip/testnetPool/00-DeploySFUSDCCcipTestnet.s.sol:DeploySFUSDCCcipTestnet $(NETWORK_ARGS)

ccip-deploy-sf-usdc-arb-sepolia-testnet:
	@forge script deploy/ccip/testnetPool/00-DeploySFUSDCCcipTestnetArbSepolia.s.sol:DeploySFUSDCCcipTestnetArbSepolia $(NETWORK_ARGS)

ccip-deploy-source-pool-testnet:
	@forge script deploy/ccip/testnetPool/01-DeployBurnMintTokenPoolSourceTestnet.s.sol:DeployBurnMintTokenPoolSourceTestnet $(NETWORK_ARGS)

ccip-source-pool-grant-roles-testnet:
	@forge script deploy/ccip/testnetPool/02-GrantSourcePoolMintBurnRoles.s.sol:GrantSourcePoolMintBurnRoles $(NETWORK_ARGS)

ccip-register-source-pool-testnet:
	@forge script deploy/ccip/testnetPool/03-RegisterAndSetPoolSelfServe.s.sol:RegisterAndSetPoolSelfServe $(NETWORK_ARGS)

ccip-deploy-dest-pool-testnet:
	@forge script deploy/ccip/testnetPool/01-DeployBurnMintTokenPoolArbSepoliaTestnet.s.sol:DeployBurnMintTokenPoolArbSepoliaTestnet $(NETWORK_ARGS)

ccip-deploy-dest-pool-testnet-legacy:
	@forge script deploy/ccip/testnetPool/01-DeploySFUSDCMintUSDCOnlyPoolArbSepolia.s.sol:DeploySFUSDCMintUSDCOnlyPoolArbSepolia $(NETWORK_ARGS)

ccip-configure-pool-lane-testnet:
	@forge script deploy/ccip/testnetPool/05-ConfigureCcipPoolLanes.s.sol:ConfigureCcipPoolLanes $(NETWORK_ARGS)

ccip-allowlist-senders:
	@forge script scripts/contract-interactions/ccip/AllowlistCcipSenders.s.sol:AllowlistCcipSenders $(NETWORK_ARGS)

ccip-test-send-message:
	@forge script scripts/contract-interactions/ccip/TestSendSaveInvestCcipMessage.s.sol:TestSendSaveInvestCcipMessage $(NETWORK_ARGS)

# Defender
defender-validate-upgrade:
	@forge clean
	@forge script deploy/defender/00-DefenderValidateUpgrade.s.sol:DefenderValidateUpgrade 

defender-prepare-referral-upgrade:
	@forge clean
	@forge script deploy/defender/DefenderPrepareReferralUpgrade.s.sol:DefenderPrepareReferralUpgrade $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

defender-prepare-ccip-sender-upgrade:
	@forge clean
	@forge script deploy/defender/DefenderPrepareCcipSenderUpgrade.s.sol:DefenderPrepareCcipSenderUpgrade $(NETWORK_ARGS)

defender-upgrade-referral:
	@forge clean
	@forge script deploy/defender/02-DefenderUpgradeReferralGateway.s.sol:DefenderUpgradeReferralGateway $(NETWORK_ARGS)
	@cp contracts/referrals/ReferralGateway.sol contracts/version_previous_contracts/ReferralGatewayV1.sol

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
	@forge script scripts/contract-interactions/ConfigStrat.s.sol:ConfigStrat $(NETWORK_ARGS)

invest-into-strat:
	@forge script scripts/contract-interactions/saveFunds/InvestIntoStrategy.s.sol:InvestIntoStrategy $(NETWORK_ARGS)

NETWORK_ARGS := --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast

ifeq ($(findstring --network arb_one,$(ARGS)),--network arb_one)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_MAINNET_RPC_URL) --trezor --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network avax_mainnet,$(ARGS)),--network avax_mainnet)
	NETWORK_ARGS := --rpc-url $(AVAX_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network base_mainnet,$(ARGS)),--network base_mainnet)
	NETWORK_ARGS := --rpc-url $(BASE_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network eth_mainnet,$(ARGS)),--network eth_mainnet)	
	NETWORK_ARGS := --rpc-url $(ETHEREUM_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network optimism_mainnet,$(ARGS)),--network optimism_mainnet)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network polygon_mainnet,$(ARGS)),--network polygon_mainnet)
	NETWORK_ARGS := --rpc-url $(POLYGON_MAINNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network arb_sepolia,$(ARGS)),--network arb_sepolia)
	NETWORK_ARGS := --rpc-url $(ARBITRUM_TESTNET_SEPOLIA_RPC_URL) --account $(TESTNET_ACCOUNT) --sender $(TESTNET_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network avax_fuji,$(ARGS)),--network avax_fuji)
	NETWORK_ARGS := --rpc-url $(AVAX_TESTNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network base_sepolia,$(ARGS)),--network base_sepolia)
	NETWORK_ARGS := --rpc-url $(BASE_TESTNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network eth_sepolia,$(ARGS)),--network eth_sepolia)
	NETWORK_ARGS := --rpc-url $(ETHEREUM_TESTNET_SEPOLIA_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network optimism_sepolia,$(ARGS)),--network optimism_sepolia)
	NETWORK_ARGS := --rpc-url $(OPTIMISM_TESTNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
else ifeq ($(findstring --network polygon_amoy,$(ARGS)),--network polygon_amoy)
	NETWORK_ARGS := --rpc-url $(POLYGON_TESTNET_RPC_URL) --account $(CCIP_ACCOUNT) --sender $(CCIP_DEPLOYER_ADDRESS) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv
endif

# Certora
fv:; certoraRun ./certora/conf/ReserveMathLib.conf
