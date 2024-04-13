const { assert } = require("chai")
const { network, deployments, ethers } = require("hardhat")
const { developmentChains } = require("../../../utils/_networks")

!developmentChains.includes(network.name)
    ? describe.skip
    : describe("TakaToken unit tests", function () {
          let takaToken

          beforeEach(async () => {
              // Get the accounts
              accounts = await ethers.getSigners()
              deployer = accounts[0]
              // Deploy contracts
              await deployments.fixture(["all"])
              takaToken = await ethers.getContract("TakaToken")
          })

          it("sanity checks", async () => {
              assert.equal(await takaToken.name(), "TAKA")
          })
      })
