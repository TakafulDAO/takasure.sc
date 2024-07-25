const { ethers } = require("hardhat")

// The purpose of this script is check the initial functions consumer configuration is correct

async function requestingBm() {
    let accounts

    const bmFetcher = await ethers.getContract("BmFetcher")

    accounts = await ethers.getSigners()

    owner = accounts[0]

    args = ["0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1"]

    console.log("Requesting BM...")

    const bm = await bmFetcher.connect(owner).sendRequest(args, { gasLimit: 4000000 })

    console.log("BM Requested!")
    console.log("BM: ", bm)
}

requestingBm()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
