const { assert } = require("chai")
const { network, deployments, ethers } = require("hardhat")
const { developmentChains, networkConfig } = require("../../../utils/_networks")

!developmentChains.includes(network.name)
    ? describe.skip
    : describe("Initialization unit tests", function () {
          const chainId = network.config.chainId

          let daoToken, usdc, takasurePool
          let accounts, deployer, daoOperator

          beforeEach(async () => {
              // Get the accounts
              accounts = await ethers.getSigners()
              deployer = accounts[0]
              daoOperator = accounts[2]
              // Deploy contracts
              await deployments.fixture(["all"])
              usdc = await ethers.getContract("USDC")
              //   daoToken = await ethers.getContract("TSToken")
              takasurePool = await ethers.getContract("TakasurePool")
          })

          it("the contribution token should be setted correctly", async () => {
              const contributionToken = await takasurePool.getContributionTokenAddress()

              const expectedContributionTokenAddress = usdc.target

              assert.equal(contributionToken, expectedContributionTokenAddress)
          })

          it("The counters initialized correctly", async () => {
              const memberIdCounter = await takasurePool.memberIdCounter()

              const expectedMemberIdCounter = 0

              assert.equal(memberIdCounter, expectedMemberIdCounter)
          })

          it("The minimum threshold initialized correctly", async () => {
              const minimumThreshold = await takasurePool.minimumThreshold()

              const expectedThreshold = 25e6

              assert.equal(minimumThreshold, expectedThreshold)
          })

          it("The service fee initialized correctly", async () => {
              const serviceFee = (await takasurePool.getReserveValues())[9]

              const expectedServiceFee = 20

              assert.equal(serviceFee, expectedServiceFee)
          })
      })
