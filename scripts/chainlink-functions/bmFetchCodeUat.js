const userAddress = args[0]

// make HTTP request
const url = `https://uat.thelifedao.io/api/v1/user/bm`
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
    console.error(bmResponse.error)
}

console.log("Response received from BM API")
console.log(bmResponse.data)

const data = bmResponse.data
if (data.Response === "Error") {
    console.error(data.Message)
    throw Error(`Functional error. Read message: ${data.Message}`)
}

console.log(`${userAddress} bm is: ${data}`)
const bm = data * 10 ** 2

return Functions.encodeUint256(bm)
