const { parseUnits, formatUnits } = require("ethers")

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
    erc20Units,
    erc20UnitsFormat,
    usdtUnits,
    usdtUnitsFormat,
}
