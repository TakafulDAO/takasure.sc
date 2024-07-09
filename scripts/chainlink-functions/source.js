// Arguments can be provided when a request is initated on-chain and used in the request source code as shown below
const userAddress = args[0];

// make HTTP request /api/v1/user/bm [get]
const url = `https://takasure.io/api/v1/user/bm`;
console.log(`HTTP GET Request to ${url}?WalletAddr=${userAddress}`);

const bmRequest = Functions.makeHttpRequest({
  url: url,
  method: 'GET',
  params: {
    WalletAddr: userAddress,
  },
  });

// Execute the API request (Promise)
const bmResponse = await bmRequest;
if (bmResponse.error) {
  console.error(bmResponse.error);
  throw Error("Request failed");
}

const data = bmResponse["data"];
if (data.Response === "Error") {
  console.error(data.Message);
  throw Error(`Functional error. Read message: ${data.Message}`);
}

// get BM