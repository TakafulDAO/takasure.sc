const { ethers } = require("hardhat")

async function joinPool() {
    let accounts

    accounts = await ethers.getSigners()
    newMember = accounts[0]

    const takasure = await ethers.getContract("TakasurePool")

    console.log("Remember to approve the TakasurePool contract to spend USDC first!")

    console.log("Joining TakasurePool...")

    const contributionAmount = 25000000n
    const membershipDuration = 5n
    try {
        await takasure
            .connect(newMember)
            .joinPool(contributionAmount, membershipDuration, { gasLimit: 3000000 })
    } catch (error) {
        console.log(error)
    }

    console.log("Joined TakasurePool!")
}

joinPool()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
