const { assert, expect } = require("chai")
const { network, deployments, ethers } = require("hardhat")
const { developmentChains } = require("../../../utils/_networks")

!developmentChains.includes(network.name)
    ? describe.skip
    : describe("MyContract unit tests", function () {
          let myContract

          beforeEach(async () => {
              // Get the accounts
              accounts = await ethers.getSigners()
              deployer = accounts[0]
              // Deploy contracts
              await deployments.fixture(["all"])
              myContract = await ethers.getContract("MyContract")
          })

          it("sanity checks", async () => {
              await myContract.setNumber(10)
              assert.equal(await myContract.myNumber(), 10n)
          })
      })
