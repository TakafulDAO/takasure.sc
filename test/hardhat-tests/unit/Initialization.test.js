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
              await deployments.fixture(["mocks", "token", "pool"])
              usdc = await ethers.getContract("USDC")
              daoToken = await ethers.getContract("TSToken")
              takasurePool = await ethers.getContract("TakasurePool")
          })

          it("the name and symbol should be returned correctly", async () => {
              const currentName = await daoToken.name()
              const currentSymbol = await daoToken.symbol()

              const expectedName = "TSToken"
              const expectedSymbol = "TST"

              assert.equal(currentName, expectedName)
              assert.equal(currentSymbol, expectedSymbol)
          })

          //   it("the roles should be assigned correctly", async () => {
          //       const DEFAULT_ADMIN_ROLE = await daoToken.DEFAULT_ADMIN_ROLE()
          //       const MINTER_ROLE = await daoToken.MINTER_ROLE()
          //       const BURNER_ROLE = await daoToken.BURNER_ROLE()

          //       const isAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, daoOperator.address)
          //       const deployerIsAdmin = await daoToken.hasRole(DEFAULT_ADMIN_ROLE, deployer.address)
          //       const isMinter = await daoToken.hasRole(MINTER_ROLE, takasurePool.target)
          //       const isBurner = await daoToken.hasRole(BURNER_ROLE, takasurePool.target)

          //       assert.isTrue(isAdmin)
          //       assert.isFalse(deployerIsAdmin)
          //       assert.isTrue(isMinter)
          //       assert.isTrue(isBurner)
          //   })

          it("should check for the members module's owner", async () => {
              const currentOwner = await takasurePool.owner()
              const expectedOwner = daoOperator.address

              assert.equal(currentOwner, expectedOwner)
          })

          it("the contribution token should be setted correctly", async () => {
              const contributionToken = await takasurePool.getContributionTokenAddress()

              const expectedContributionTokenAddress = usdc.target

              assert.equal(contributionToken, expectedContributionTokenAddress)
          })

          it("the takasure pool should be setted correctly", async () => {
              const daoTokenAddress = await takasurePool.getTokenAddress()

              const expectedContributionToken = daoToken.target

              assert.equal(daoTokenAddress, expectedContributionToken)
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
