const userAddress = args[0]

// make HTTP request
const url = `http://34.228.189.184:5559/api/v1/user/bm`
console.log(`HTTP GET Request to ${url}?fsyms=${userAddress}`)

const bmRequest = Functions.makeHttpRequest({
    url: url,
    method: "GET",
    params: {
        WalletAddr: userAddress,
    },
})

console.log("Request sent to BM API")
console.log("Waiting for response...")

// Execute the API request (Promise)
const bmResponse = await bmRequest
if (bmResponse.error) {
    return Functions.encodeUint256(0)
}

const data = bmResponse["data"]
if (data.Response === "Error") {
    console.error(data.Message)
    throw Error(`Functional error. Read message: ${data.Message}`)
}

const bm = data["BenefitMultiplier"]
console.log(`${userAddress} bm is: ${bm}`)

return Functions.encodeUint256(bm)
