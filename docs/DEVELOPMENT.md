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

## How a run is split between workers

Each pass of a run is split into shards, one per source file or sim file, and up to `-Djobs` workers run the shards at once, each under its own kcov with its own work, result, coverage and progress files. A shard never splits a file, so the calls of one function stay in one worker and it reads that file's conditions once. The driver reads what the shards found in shard order, not in the order the workers finish, and the shards do not depend on the number of workers, so the report is the same with one worker or many. Every worker writes how far it has got to a progress file and the driver prints one line for all of them.

## How results are kept between runs

`src/framework/results_cache.zig` keeps the complete result of each source file and sim file in `.zig-cache/flt-results/`, and `src/framework/run_cache.zig` connects it to a run. A result is stored with the file's key: a hash of the file and of everything it imports at any depth, its sim file, every `global.sim.zig` and a salt the build makes from the directory Faultline is in, the target and the optimisation. A fetched Faultline is in a directory Zig names after a hash of the package's contents, so a new or changed one gives new keys at no cost to a run. A Faultline used from a local path keeps its directory however it is edited, so run `zig build flt clear` after changing Faultline's code, or pass `-- --no-cache`, as the smoke tests do. Imports of a module by name are followed through the table of modules the build writes beside the copy of the project's files (`src/cmd/module_table.zig`). A source file's result also names every file whose calls ran any of its lines, with their keys, because a code path can be exercised by another file's calls. A run uses a result only while its key and every one of those keys are unchanged, and runs again every file that exercised the code paths of a file it runs again. Failures are listed in table order, so a run from the cache reports them in the order the run that made them did.

## How crashes are kept between runs

`src/framework/crash_store.zig` reads and writes `.zig-cache/flt-crashes.txt`, one replay token per line, and the driver passes the path with `--crashes`. Before any call, the driver replays every kept token with `src/framework/replay.zig`, adds each that still fails to the run's failures and drops each that no longer names a call. After the run it writes back the kept tokens followed by the token of every crash the run found, leaving out a token that differs from a kept one only in its seed, unless one of its values (written with `s`) was drawn from that seed. The file is outside `flt-results/`, so `--no-cache` and `zig build flt clear` leave it alone. The smoke tests throw it away before each example so an example prints what its `expected.txt` holds, and check keeping crashes on a copy of `examples/non-working/36-crash-under-injection`.

## CI

`.github/workflows/ci.yml` runs on every push and pull request, on Linux only because Faultline needs kcov and `/proc`. It runs two jobs at once: one runs `zig build` and `zig build test`, and the other builds kcov from its tagged source, keeping the build between runs, and runs `bash scripts/smoke.sh`.

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
