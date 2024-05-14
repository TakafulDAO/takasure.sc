# Takasure Smart Contracts 

- [Takasure Smart Contracts](#takasure-smart-contracts)
  - [Resources](#resources)
  - [Deployed Contracts](#deployed-contracts)
  - [Version Control](#version-control)
  - [Requirements](#requirements)
  - [Quickstart](#quickstart)
    - [env](#env)
  - [Usage](#usage)
    - [Compile](#compile)
    - [Testing](#testing)
    - [Deploy](#deploy)
  - [Contribute](#contribute)
     
## Resources 
TODO

## Deployed Contracts
TODO

## Version Control 
To view the testnet and mainnet deployments, check out the tags under this repo. The tag naming convention follows [Semantic Versioning](https://semver.org/)
* Deployment versions start from v1.0.0
* Tags related to testnet start with dev. Ex. dev1.0.0
  
## Requirements

- [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
  - You'll know you did it right if you can run `git --version` and you see a response like `git version x.x.x`
- [foundry](https://getfoundry.sh/)
  - Run
  ```
  curl -L https://foundry.paradigm.xyz | bash
  ```
  - You'll know you did it right if you can run `forge --version` and you see a response like `forge 0.2.0 (816e00b 2023-03-16T00:05:26.396218Z)`

## Quickstart

1. Clone the repo and install the dependencies

```
git clone https://github.com/TakafulDAO/takasure.sc
cd takasure.sc
yarn install
forge install
forge build
```

2. Create a .env file with the variables explained on the next section. You can also check the `.env.example` file

### env
1. Private keys. For development purposes, this three private keys can be the same
    + DEPLOYER_PK
    + ARBITRUM_MAINNET_DEPLOYER_PK
    + TESTNET_DEPLOYER_PK
2. Deployers address. Address of the private keys above. As explained before for development purposes, this addresses can be the same
    + DEPLOYER_ADDRESS
    + TESTNET_DEPLOYER_ADDRESS
3. Mainnet RPC URL
    + ARBITRUM_MAINNET_RPC_URL
4. Testnet RPC_URL
 + ARBITRUM_TESTNET_SEPOLIA_RPC_URL
5. Scans api keys. [here](https://docs.arbiscan.io/getting-started/viewing-api-usage-statistics)
    + ARBISCAN_API_KEY
6. Price feeds api keys. You can get it [here](https://coinmarketcap.com/api/)
    + COINMARKETCAP_API_KEY=
7. Features. Especial features for tests
    + FORK= true to fork arbitrum mainnet. Most of the tests require this to be set to true
    + GAS_REPORT= true to get gas report on the output file
    + SIZE= true to get contract's size report when compile

> [!CAUTION]
> Never expose private keys with real funds

## Usage

### Compile

Use `yarn compile` or `forge build`

> [!TIP]
> `forge build` will compile the contracts inside the contracts and test folder. Use it if you change the tests

### Testing

- Use `yarn test` to run hardhat tests
- Use `forge test` to run foundry tests
- Use `make test` to run both
- Use `forge coverage` to get the coverage report

> [!TIP]
> To run a specific test use `forge test --mt <TEST_NAME>`

> [!NOTE]
> The deployments are managed by hardhat. So the hardhat test check all the initializations and the foundry tests check the contract's logic

### Deploy
TODO

## Contribute 
Contribute by creating a gas optimization or no risk issue through github issues. 
Contribute by sending critical issues/ vulnerabilities to info@takadao.io. 

[top](#Takasure-smart-contracts)


