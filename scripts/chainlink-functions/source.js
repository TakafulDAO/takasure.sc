// Arguments can be provided when a request is initated on-chain and used in the request source code as shown below
const userAddress = args[0]

// make HTTP request
const url = `http://34.228.189.184:5559/api/v1/user/bm`
console.log(`HTTP GET Request to ${url}?fsyms=${userAddress}`)

// construct the HTTP Request object. See: https://github.com/smartcontractkit/functions-hardhat-starter-kit#javascript-code

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
    // console.error(bmResponse.error)
    // throw Error("Request failed")
    return Functions.encodeUint256(0)
}

const data = bmResponse["data"]
if (data.Response === "Error") {
    console.error(data.Message)
    throw Error(`Functional error. Read message: ${data.Message}`)
}

// extract the price
const bm = data["BenefitMultiplier"]
console.log(`${userAddress} bm is: ${bm}`)

return Functions.encodeUint256(bm)
