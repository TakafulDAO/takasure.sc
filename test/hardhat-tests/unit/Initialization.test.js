const { assert } = require("chai")
const { network, deployments, ethers } = require("hardhat")
const { developmentChains } = require("../../../utils/_networks")

!developmentChains.includes(network.name)
    ? describe.skip
    : describe("Initialization unit tests", function () {
          let takaToken

          beforeEach(async () => {
              // Get the accounts
              accounts = await ethers.getSigners()
              deployer = accounts[0]
              // Deploy contracts
              await deployments.fixture(["all"])
              takaToken = await ethers.getContract("TakaToken")
              takasurePool = await ethers.getContract("TakasurePool")
              membersModule = await ethers.getContract("MembersModule")
          })

          it("the name and symbol should be returned correctly", async () => {
              const currentName = await takaToken.name()
              const currentSymbol = await takaToken.symbol()

              const expectedName = "TAKA"
              const expectedSymbol = "TKS"

              assert.equal(currentName, expectedName)
              assert.equal(currentSymbol, expectedSymbol)
          })

          it("the roles should be assigned correctly", async () => {
              const DEFAULT_ADMIN_ROLE = await takaToken.DEFAULT_ADMIN_ROLE()
              const MINTER_ROLE = await takaToken.MINTER_ROLE()
              const BURNER_ROLE = await takaToken.BURNER_ROLE()

              const isAdmin = await takaToken.hasRole(DEFAULT_ADMIN_ROLE, deployer.address)
              const isMinter = await takaToken.hasRole(MINTER_ROLE, takasurePool.target)
              const isBurner = await takaToken.hasRole(BURNER_ROLE, takasurePool.target)

              assert.isTrue(isAdmin)
              assert.isTrue(isMinter)
              assert.isTrue(isBurner)
          })

          it("the taka token should be assigned correctly in the takasure pool", async () => {
              const takaTokenAddress = await takasurePool.getTakaTokenAddress()
              const expectedAddress = takaToken.target

              assert.equal(takaTokenAddress, expectedAddress)
          })

          it("should check for the members module's owner", async () => {
              const currentOwner = await membersModule.owner()
              const expectedOwner = deployer.address

              assert.equal(currentOwner, expectedOwner)
          })
      })
