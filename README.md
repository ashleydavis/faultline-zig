# Faultline

Faultline runs every code path in your project, both happy paths and error handling paths. It's job is to get to 100% code coverage and if possible make your code crash (so you can then adjust your code to make it uncrashable).

Faultline woprks automatically as far is it can, but usually needs some help from you (explained below) to find all code paths from every function in your project.

Faultline does not check that your code does what it is supposed to. That is for unit, smoke, integration and end-to-end tests. Faultline checks that your code survives every input and failure that is thrown at it.

## What Faultline does

Faultline calls every Zig function in your project with chosen inputs, injects every failure at every call that could fail that way and reads which lines ran from kcov. It picks failures systematically. Its few random input values come from a random number generator. A replay uses the seed of the run it replays, so it gets the same results.

Faultline is a library your project depends on. `zig build flt` runs Faultline.

## What you do

- Install [kcov](https://github.com/SimonKagstrom/kcov). kcov is required.
- Write value factories for your own types that Faultline cannot instantiate, so Faultline can build inputs to your functions.
- Write scenarios for code paths that Faultline cannot exercise.
- Optionally write expectation functions: checks that run after every call and after every scenario.

## Resources

- [Quick reference](docs/QUICK-REF.md) to add Faultline to a repository and use it.
- [User guide](docs/USER-GUIDE.md) for the full detail.
- [Contract](docs/CONTRACT.md) for what Faultline promises.
- [Failures](docs/FAILURES.md) for every failure type Faultline injects.
- [Output](docs/OUTPUT.md) for what Faultline prints and what each line means.
- [Development](docs/DEVELOPMENT.md) to work on Faultline itself.
