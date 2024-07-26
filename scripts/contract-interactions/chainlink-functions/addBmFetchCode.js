const { ethers } = require("hardhat")
const fs = require("fs")
const path = require("path")

async function addBmFetchCode() {
    let accounts

    const bmConsumer = await ethers.getContract("BenefitMultiplierConsumer")

    accounts = await ethers.getSigners()

    owner = accounts[0]

    console.log("Adding BM Fetch Code to BenefitMultiplierConsumer Contract...")

    const sourceCode = fs.readFileSync(path.resolve(__dirname, "bmFetchCode.js")).toString()

    await bmConsumer.connect(owner).setBMSourceRequestCode(sourceCode)

    console.log("BM Fetch Code added to BenefitMultiplierConsumer Contract!")
}

addBmFetchCode()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
