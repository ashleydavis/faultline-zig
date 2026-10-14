# Development

How to work with and contribute to this repo.

## Setup

Install dependencies:

```sh
mise install
```

Install kcov as well. Faultline and the example tests need it. If your distribution has a kcov package, install that:

```sh
sudo apt install kcov
```

Otherwise follow the [kcov installation instructions](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md).

## Commands

- `zig build` compiles the Faultline library and its tests.
- `zig build test` runs the unit tests, in the default optimisation and again in `ReleaseSafe`.
- `bash scripts/smoke.sh` runs smoke tests against all examples.
- `bash scripts/test-everything.sh` runs all tests in parallel, failing out at the first problem. Only runs tests when appropriate code has changed since the last successful test run.

## The pre-commit hook

The repository has a git pre-commit hook in `.githooks/pre-commit`. It runs `bash scripts/test-everything.sh` and refuses the commit if any check fails.

Run this once each time you clone the repo:

```sh
bash scripts/install-hooks.sh
```

## The examples

Every directory under `examples/` is a small project of its own: it declares Faultline as a dependency and calls `addFaultTest` in its own `build.zig`, exactly as a real project does.

`bash scripts/smoke.sh` runs `zig build flt` in each of them. `examples/working/` is one feature per directory and `examples/non-working/` is one failure per directory.

Run one example on its own:

```sh
bash scripts/smoke.sh 01-one-function
```
