const { network } = require("hardhat")
const { now } = require("./units")

const advanceTime = async (seconds) => {
    await network.provider.send("evm_increaseTime", [seconds])
    await network.provider.send("evm_mine", [])
}

/**
 * @param times amount of the param seconds
 * @param seconds hour, day, week, month or year
 * Example advanceTimebyDate(5, day)
 */
const advanceTimeByDate = async (times, seconds) => {
    for (let i = 0; i < times; i++) {
        await advanceTime(seconds)
    }
}

const setTimeFromNow = async (times, seconds) => {
    return now + times * seconds
}

const advanceBlocks = async (numBlocks) => {
    for (let i = 0; i < numBlocks; i++) {
        await network.provider.send("evm_mine")
    }
}

const impersonateAccount = async (account) => {
    return hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [account],
    })
}

const toWei = (num) => String(ethers.parseEther(String(num)))
const fromWei = (num) => Number(ethers.formatEther(num))

module.exports = {
    // Time utilities
    advanceTime,
    advanceTimeByDate,
    setTimeFromNow,
    advanceBlocks,
    // Accounts
    impersonateAccount,
    // Payments
    toWei,
    fromWei,
}
