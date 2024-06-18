# Running the certora verification tool

These instructions detail the process for running CVT on the contracts.

Documentation for CVT and the specification language are available
[here](https://docs.certora.com/en/latest/index.html)

## Adapting to changes

Some of the rules require the code to be simplified in various ways. Our primary tool for performing these simplifications is to run verification on a
contract that extends the original contracts and overrides some of the methods. These "harness" contracts can be found in the `certora/harness` directory.

This pattern does require some modifications to the original code: some methods need to be made virtual or public, for example. This is called `unsound test` read more about it [here](https://docs.certora.com/en/latest/docs/user-guide/glossary.html#term-unsound) These changes are handled by
applying a patch to the code before verification.

## Running the verification

Initial step: if certora prover is not installed follow the steps [here](https://docs.certora.com/en/latest/docs/user-guide/install.html)

First step is to create the `munged/` directory. This has to be done in the `certora/` directory. Run the following:

```sh
cd certora/
make munged
```

