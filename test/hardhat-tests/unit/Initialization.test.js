const { assert } = require("chai")
const { network, deployments, ethers } = require("hardhat")
const { developmentChains, networkConfig } = require("../../../utils/_networks")

!developmentChains.includes(network.name)
    ? describe.skip
    : describe("Initialization unit tests", function () {
          const chainId = network.config.chainId

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

              const expectedName = "TAKASURE"
              const expectedSymbol = "TAKA"

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

          it("the tokens should be setted correctly", async () => {
              const tokens = await membersModule.getTokensAddresses()
              const contributionToken = tokens[0]
              const takaTokenAddress = tokens[1]

              const expectedContributionToken = networkConfig[chainId]["usdc"]
              const expectedTakaToken = takaToken.target

              assert.equal(contributionToken, expectedContributionToken)
              assert.equal(takaTokenAddress, expectedTakaToken)
          })

          it("The counters initialized correctly", async () => {
              const fundIdCounter = await membersModule.fundIdCounter()
              const memberIdCounter = await membersModule.memberIdCounter()

              const expectedFundIdCounter = 0
              const expectedMemberIdCounter = 0

              assert.equal(fundIdCounter, expectedFundIdCounter)
              assert.equal(memberIdCounter, expectedMemberIdCounter)
          })

          it("The counters initialized correctly", async () => {
              const fundIdCounter = await membersModule.fundIdCounter()
              const memberIdCounter = await membersModule.memberIdCounter()

              const expectedFundIdCounter = 0
              const expectedMemberIdCounter = 0

              assert.equal(fundIdCounter, expectedFundIdCounter)
              assert.equal(memberIdCounter, expectedMemberIdCounter)
          })

          it("The minimum threshold initialized correctly", async () => {
              const minimumThreshold = await membersModule.getMinimumThreshold()

              const expectedThreshold = 25e6

              assert.equal(minimumThreshold, expectedThreshold)
          })

          it("The wakala fee initialized correctly", async () => {
              const wakalaFee = await membersModule.getWakalaFee()

              const expectedWakalaFee = 20

              assert.equal(wakalaFee, expectedWakalaFee)
          })
      })
