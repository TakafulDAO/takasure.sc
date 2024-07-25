const { ethers } = require("hardhat")
const fs = require("fs")
const path = require("path")

async function addBmFetchCode() {
    let accounts

    const bmFetcher = await ethers.getContract("BmFetcher")

    accounts = await ethers.getSigners()

    owner = accounts[0]

    console.log("Adding BM Fetch Code to BmFetcher Contract...")

    const sourceCode = fs.readFileSync(path.resolve(__dirname, "bmFetchCode.js")).toString()

    await bmFetcher.connect(owner).setBMSourceRequestCode(sourceCode)

    console.log("BM Fetch Code added to BmFetcher Contract!")
}

addBmFetchCode()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
