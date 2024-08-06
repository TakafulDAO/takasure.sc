const toWei = (num) => String(ethers.parseEther(String(num)))
const fromWei = (num) => Number(ethers.formatEther(num))

module.exports = {
    toWei,
    fromWei,
}
