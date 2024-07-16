## Adapting to changes

Some of the rules require the code to be simplified in various ways. The primary tool for performing these simplifications will be a verification on a contract that extends the original contracts and overrides some of the methods. These "harness" contracts can be found in the `certora/harness` directory.

This pattern does require some modifications to the original code: some methods need to be made public or some functions will be rearrange in several internal functions, for example. This is called `unsound test` read more about it [here](https://docs.certora.com/en/latest/docs/user-guide/glossary.html#term-unsound) These changes are handled by applying a patch to the code before verification.

# Running the certora verification tool

Initial step: if certora prover is not installed follow the steps [here](https://docs.certora.com/en/latest/docs/user-guide/install.html)

Documentation for CVT and the specification language are available
[here](https://docs.certora.com/en/latest/index.html)

>[!IMPORTANT]
> We recomend you use solc-select to set the solc version

## Running the verification

1. First step is to set the solidity compiler version with:

```sh
solc-select use 0.8.25
```

>[!TIP]
> Install the version previously with `solc-select install 0.8.25`

>[!WARNING]
> If not using solc-select add an item to the `.conf` files `"solc": 0.8.25`

2. Second write your certora api ke into environment

```sh
export CERTORAKEY=<your_certora_api_key>
echo $CERTORAKEY
```

3. Now enter the certora folder, and create the `munged/` directory. If it is the first time running certora in this project use

```sh
cd certora/
make munged
```

If not

```sh
cd certora/
make clean
make munged
```

4. Finally run the config file in the root folder

```sh
cd ..
certoraRun ./certora/conf/ReserveMathLib.conf
```

Or you can use the make command in the makefile with

```sh
cd ..
make fv
```




