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
make all
```

2. Create a .env file with the variables explained on the next section. You can also check the `.env.example` file

### env
1. Private keys. For development purposes, this is used only in the script to check the chainlink functions script
    + TESTNET_DEPLOYER_PK
2. Deployers addresses
    + MAINNET_DEPLOYER_ADDRESS
    + TESTNET_DEPLOYER_ADDRESS
3. Mainnet RPC URL
    + ARBITRUM_MAINNET_RPC_URL
4. Testnet RPC_URL
    + ARBITRUM_TESTNET_SEPOLIA_RPC_URL
5. Scans api keys. [here](https://docs.arbiscan.io/getting-started/viewing-api-usage-statistics)
    + ARBISCAN_API_KEY
6. Accounts. This are the names of the accounts encripted with `cast wallet import`
    + MAINNET_ACCOUNT=
    + TESTNET_ACCOUNT=

> [!CAUTION]
> Never expose private keys with real funds

## Usage

### Compile

Use `forge build` or `make build`

### Testing

Use `forge test` or `make test`
Use `forge coverage --ir-minimum` to get the coverage report

For special test cases related to chainlink services be aware of the following:
- For chainlink functions there is no available tool to test it in Foundry. You can use the script `scripts/chainlink-functions/requestSepolia.js` to test the functions behaviour and output.
- For chainlink ccip there are some tests to check events, errors and settings, but the main functionality was tested in live environments, please check the `deployments` folder to find the testnet deployment for the Receiver and the Sender contracts, and interact with them to check the functionality. This is one of the ways recommended in the Chainlink documentation to test the functionality of the contracts.

> [!TIP]
> To run a specific test use `forge test --mt <TEST_NAME>`

>[!NOTE]
> Some formal verification is made in this repo. Follow the instructions in the README file in the `certora` folder

### Deploy
TODO

## Contribute 
Contribute by creating a gas optimization or no risk issue through github issues. 
Contribute by sending critical issues/ vulnerabilities to info@takadao.io. 

[top](#Takasure-smart-contracts)


