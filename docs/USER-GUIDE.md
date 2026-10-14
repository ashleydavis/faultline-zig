# Fault testing a repository with Faultline

Faultline calls every function in your repository with chosen inputs, injects failures at every call that could fail and reads which lines ran from kcov. It reports every code path that no call exercised.

## Step 1: Add the dependency

```sh
zig fetch --save=faultline git+https://github.com/ashleydavis/faultline
```

## Step 2: Install kcov

kcov is required. kcov watches a program from outside and reports which lines ran. If Faultline cannot find kcov, it prints one sentence saying so and exits 1.

Where your distribution has a package:

```sh
sudo apt install kcov
```

Otherwise follow the [kcov installation instructions](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md). Faultline finds `kcov` on the PATH, or you name it with `-Dkcov=<path>`.

## Step 3: Add the build step

Add one line to your `build.zig`:

```zig
@import("faultline").addFaultTest(b, .{});
```

That adds a build step named `flt`.

Faultline takes your modules from your build: every module you register with `b.addModule`. A module made with `b.createModule` is not registered, so Faultline cannot see it.

### Choose what Faultline tests

Faultline looks through your project for Zig files and fault tests every one it finds. These options on `addFaultTest` change that.

#### `.include`: name the files and directories to test

To test only some of your code, name it. `.include` takes paths to files and directories, relative to your project root. This project keeps code under `lib/text` and `lib/io`, has one more file to test and has a `scripts` directory that should not be tested:

```
yourproject/
    build.zig
    main.zig
    lib/
        text/
            casing.zig
        io/
            reader.zig
    scripts/
        generate.zig
```

```zig
@import("faultline").addFaultTest(b, .{
    .include = &.{
        "lib/text",
        "lib/io",
        "main.zig",
    },
});
```

Faultline tests only those paths. `scripts/generate.zig` is left alone. Naming `.include` turns off Faultline's own search for Zig files, so list everything you want tested.

#### `.exclude`: leave out files and directories

Benchmarks and test harnesses are code too, so Faultline takes them for source and asks you to cover their code paths. A benchmark exercises your code and is not code you want tested. `.exclude` takes paths to files and directories, relative to your project root:

```
yourproject/
    build.zig
    sorting.zig
    bench/
        sorting_bench.zig
    tools/
        harness.zig
        helper.zig
```

```zig
@import("faultline").addFaultTest(b, .{
    .exclude = &.{
        "bench",
        "tools/harness.zig",
    },
});
```

This leaves out everything under `bench` and the one file `tools/harness.zig`. `tools/helper.zig` is still tested.

### Build options

Type these after `zig build flt` on the command line, for example `zig build flt -Dfile=src/format.zig`:

- `-Dfile=<path>` and `-Dfunction=<name>` narrow Faultline to one file or one function. The coverage percentage then covers only what you asked for.
- `-Dreport=<path>` moves the full checklist.
- `-Dkcov=<path>` names kcov.
- `-Dreplay="<token>"` reproduces a failure Faultline already reported.
- `-Djobs=<n>` sets how many workers run at once. By default there is one per processor core. The report is the same whatever the number.

## Step 4: Run Faultline

```sh
zig build flt
```

Faultline prints a checklist of what you need to do have it exercise every code path. Faultline exits 1 below 100% and 0 at 100%.

## Step 5: Read the report

The report has a block per file and a line per function:

```
  packages/example/src/format.zig
    ok   formatFileSize                     9/9 code paths, 120 calls
```

A function is done when its line reads `ok`, which means every one of its code paths was exercised.

For each code path that was not exercised, the report says what to do:

```
  FAIL 1 code path that no call exercised:
      sizing.zig:9 "if:9:false" in isLarge: Faultline found no value that exercises this branch.

  One thing to do:
    Write a scenario exercising the false side of the if at sizing.zig:9 in isLarge.
```

## How Faultline chooses what to call

Faultline's goal is to exercise every code path in every function. It asks kcov which code paths have been exercised so far and it keeps choosing input values and injecting failures until every code path has been exercised or it has run out of values and failures to try for the rest. A failure matters because the code that handles it is a code path too.

For each function, Faultline does the following, in order:

1. Faultline calls the function with the input values it picks (listed below). Every call shows the places where the function uses something that can fail: an allocation, a file operation, a network call, a clock reading or a write.
2. For each place it has seen and each failure that can happen there, Faultline calls the function again and makes exactly that failure happen. `FAILURES.md` lists the failures. These calls can reach new places and Faultline does the same for them.
3. Faultline asks kcov which code paths have still not been exercised. For each one it reads the conditions in your source and calls the function again with values on each side of them.

Faultline makes the calls of steps 1 and 2 in rounds and asks kcov after each round which code paths are exercised. It stops calling a function once every one of that function's own code paths is exercised and so is every code path of the functions in the same file that Faultline does not call itself, because those are reached only through their callers.

Faultline gives up on a code path only when it has tried every value and every failure it has for that code path: the input values it picks, the values it reads from the conditions in your source and every failure at every place it can happen. A code path it gives up on becomes a checklist item asking for a scenario.

Faultline picks input values from the boundary values of each type (zero, one, minus one, the type's minimum and maximum, an empty slice, a one element slice, an empty string, a one character string, false and true, every enum tag, null and not null), plus a few from a random number generator. Each run starts the generator from a new seed. A replay starts it from the seed of the run it replays, so the same values come up again.

Faultline calls each function with every combination of the values it has for its parameters: its own values and your value factories alike.

## Step 6: Write value factories for your own types that Faultline cannot instantiate

Faultline instantiates integers, floats, booleans, enums, optionals, errors, slices, arrays, plain structs, tagged unions and pointers to any of those. It also provides the allocator, `std.Io`, the network, the clock, `std.Random` and a writer. For your own types that it cannot instantiate, you write a value factory.

A value factory is a public function in a sim file that returns a value of one of those types:

```zig
pub fn workingLoader() ImageLoader {
    return .{
        .source = my_test_bytes(),
    };
}
```

Faultline finds value factories by their return type. The sim file sits beside the file being tested: `image.sim.zig` for `image.zig`. A factory may take parameters and Faultline provides them.

Faultline uses a sim file's value factories only for the functions in the file beside it: the factories in `image.sim.zig` are used for the functions in `image.zig` and for no other file. When functions in several files take an `ImageLoader`, each of those files needs factories for it in its own sim file. This applies to every type a factory returns, including strings and numbers.

A value factory that several files need goes in a sim file named `global.sim.zig`. Faultline uses the factories in a `global.sim.zig` for the functions in every file. A string or number factory there reaches every function that takes a string or a number, so keep those in the sim file beside the file that needs them.

Write as many factories as you like for one of those types. A function that takes an `ImageLoader` is called with each of them.

To return a different value on each call, put the function on a struct:

```zig
pub const MyLoaders = struct {

    //
    // Whatever state variables you want.
    //

    pub fn loader(self: *MyLoaders) ImageLoader {
        //
        // Returns the next loader in whatever sequence you want.
        //
    }
};
```

Faultline finds it the same way, by the type the function returns.

### One factory per fault

Some branches run only when something goes wrong: a missing file, a response that will not parse. Write one factory per fault and Faultline calls your code with the working value and with each broken one:

```zig
pub fn workingLoader() ImageLoader {
    return .{
        .source = my_test_bytes(),
    };
}

pub fn missingFileLoader() ImageLoader {
    return .{
        .source = my_missing_file(),
    };
}

pub fn truncatedFileLoader() ImageLoader {
    return .{
        .source = my_truncated_bytes(),
    };
}
```

Faults in the allocator, files, network, clock and writer need no factory. Faultline creates those automatically.

## Step 7: Write scenarios for code paths Faultline cannot exercise

Faultline reads the conditions in your source and tries values on each side of them. It cannot work out a value for a condition whose result has to be calculated, such as `if (checksum(data) == 0x1f2e)`, or for one that needs several arguments to line up. For those it asks for a scenario: a function in the sim file that calls your function with values you choose.

```zig
const sim = @import("sim");
const image = @import("image.zig");

pub fn runPngHeaderScenario(context: *sim.ScenarioContext) anyerror!void {
    const format = image.formatOf("PNG");

    try context.expect(@src(), format == .png, "PNG to be read as the png format");
}
```

Faultline recognises a scenario by its parameter, `*sim.ScenarioContext`. The function can have any name.

The context gives a scenario:

- `context.faults`: the failures Faultline can inject, so a scenario can ask for one at a chosen place.
- `context.io`: a `std.Io` whose filesystem and network are simulated in memory. Faultline makes them fail as listed in `FAILURES.md`.
- `context.allocator`: an allocator Faultline can make fail.
- `context.expect(@src(), condition, "what you expected")`: an expectation, as in a unit test. If the condition is false, the expectation fails and Faultline reports it.

A scenario that returns an error has not failed. Your code returns errors when Faultline injects failures, so only a false expectation fails a scenario.

## Step 8: Write expectation functions to check expectations after every call

An expectation function checks expectations after a call or after a scenario:

```zig
const sim = @import("sim");

pub fn rowsAndLinksAgree(context: *sim.ExpectationContext) anyerror!void {
    try context.expect(@src(), rows_match_links(context), "every row to have its link");
}
```

Faultline recognises an expectation function by its parameter, `*sim.ExpectationContext`. The function can have any name. Expectation functions in `image.sim.zig` run:

- After every call Faultline makes to a function in `image.zig`, whatever input values and injected failure that call used.
- After every scenario in `image.sim.zig`.

When one fails, Faultline prints the function and call (or the scenario), your sentence, the line and the replay command.

## Adopting Faultline gradually

You do not have to reach 100% for the whole project at once. Use `.include` to start with a small part of your code, reach 100% for that part, then add more. Start with a single file or a directory.

Start with one file:

```zig
@import("faultline").addFaultTest(b, .{
    .include = &.{
        "lib/text/casing.zig",
    },
});
```

When `zig build flt` exits 0 for that file, add the next file or a whole directory:

```zig
@import("faultline").addFaultTest(b, .{
    .include = &.{
        "lib/text/casing.zig",
        "lib/text/trim.zig",
        "lib/io",
    },
});
```

Keep adding paths until everything is included. Then remove `.include` and `zig build flt` covers the whole project.

The coverage percentage and the exit code cover only what `.include` names, so `zig build flt` exits 0 at 100% of that part.

## Sim files

A `<name>.sim.zig` file holds the value factories, scenarios and expectation functions for `<name>.zig`:

```zig
const sim = @import("sim");

pub fn myValueFactory() SomeValue {
    // Returns a value to pass to your functions.
}

pub fn myScenario(context: *sim.ScenarioContext) anyerror!void {
    // Calls your functions with specific values.
    _ = context;
}

pub fn myExpectation(context: *sim.ExpectationContext) anyerror!void {
    // Checks expectations after a call or a scenario.
    _ = context;
}
```

## A limit of kcov

kcov counts a line as run whether or not the body of a branch on that line ran. In `if (x) return 1;` on one line, kcov cannot tell whether the `return` ran, so the branch can look covered when only its condition ran. Put the body on its own line and kcov can tell the two apart.

## When Faultline finds a failure

Faultline prints what failed and the command that repeats it:

```
The call to parseHeader failed with ParsedWrong.
Reproduce it with: zig build flt -Dreplay="<token>"
```

The token holds the plan of injected failures and the values chosen. Run the command and Faultline drives the same calls in the same order and gives the same answer, with no other flag, environment or file.
