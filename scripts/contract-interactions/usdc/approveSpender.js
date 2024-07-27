const { ethers } = require("hardhat")

async function approveSpender() {
    let accounts

    accounts = await ethers.getSigners()
    newMember = accounts[0]

    const takasure = await ethers.getContract("TakasurePool")
    const usdc = await ethers.getContract("USDC")

    const contributionAmount = 25000000n

    console.log("Approving TakasurePool contract to spend USDC...")
    await usdc.connect(newMember).approve(takasure.target, contributionAmount)
    console.log("Approved TakasurePool contract to spend USDC!")
}

approveSpender()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error)
        process.exit(1)
    })
