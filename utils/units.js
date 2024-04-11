const { parseUnits, formatUnits } = require("ethers")

const now = Math.floor(Date.now() / 1000)
const minute = 60
const hour = 3600
const day = 24 * hour
const week = day * 7
const month = (365 / 12) * day
const year = month * 12

function erc20Units(amount) {
    return parseUnits(amount, 18)
}

function erc20UnitsFormat(amount) {
    return formatUnits(amount, 18)
}

function usdtUnits(amount) {
    return parseUnits(amount, 6)
}

function usdtUnitsFormat(amount) {
    return formatUnits(amount, 6)
}

module.exports = {
    now,
    minute,
    hour,
    day,
    week,
    month,
    year,
    erc20Units,
    erc20UnitsFormat,
    usdtUnits,
    usdtUnitsFormat,
}
