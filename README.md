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
    - [Formal Verification](#formal-verification)
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
1. Deployers addresses
    + TESTNET_DEPLOYER_ADDRESS
2. Mainnet RPC URL
    + ARBITRUM_MAINNET_RPC_URL
3. Testnet RPC_URL
    + ARBITRUM_TESTNET_SEPOLIA_RPC_URL
4. Scans api keys. [here](https://docs.etherscan.io/etherscan-v2/getting-an-api-key)
    + ETHERSCAN_API_KEY
5. Accounts. This are the names of the accounts encripted with `cast wallet import`
    + TESTNET_ACCOUNT=

> [!CAUTION]
> Never expose private keys with real funds

## Usage

### Compile

Use `forge build` or `make build`

### Testing

Use `forge test` or `make test`
Use `forge coverage --ir-minimum` or `make coverage-report` to get the coverage report

> [!TIP]
> To run a specific test use `forge test --mt <TEST_NAME>` or `forge test --mc <TEST_CONTRACT_NAME>` to run the tests in a file

### Formal Verification

Some contracts are formally verified using Certora. Some of the rules require the code to be simplified in various ways. The primary tool for performing these simplifications will be a verification on a contract that extends the original contracts and overrides some of the methods. These "harness" contracts can be found in the `certora/harness` directory.

This pattern does require some modifications to the original code: some methods need to be made public or some functions will be rearrange in several internal functions, for example. This is called `unsound test` read more about it [here](https://docs.certora.com/en/latest/docs/user-guide/glossary.html#term-unsound) These changes are handled by applying a patch to the code before verification.

>[!NOTE]
> Although it is possible to set up certora in  a Windows environment, it requires additional checks and steps. If you are using Windows, it is recommended to use WSL2 with a Linux distribution such as Ubuntu.

In order to run this verification you need:
- Python 3.9 or newer
- certora CLI 8.x
- solc 0.8.28
- java 21 or newer
- An account in certora and an api key

After this run

```bash
export CERTORAKEY=<your_certora_api_key>
certoraRun certora/conf/<config_file>.conf
``` 

### Deploy
TODO

## Contribute 
Contribute by creating a gas optimization or no risk issue through github issues. 
Contribute by sending critical issues/ vulnerabilities to info@takadao.io. 

[top](#Takasure-smart-contracts)


