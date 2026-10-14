# Fault testing a repository with Faultline (the quick version)

What a repository does to start using Faultline, in order. `USER-GUIDE.md` has the detail.

## 1. Add the dependency

```sh
zig fetch --save=faultline git+https://github.com/ashleydavis/faultline
```

## 2. Install kcov

kcov is required. Where your distribution has a package:

```sh
sudo apt install kcov
```

Otherwise follow the [kcov installation instructions](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md). Faultline finds `kcov` on the PATH, or `-Dkcov=<path>` names it. Without kcov, Faultline prints one sentence and exits 1.

## 3. Add the build step

```zig
@import("faultline").addFaultTest(b, .{});
```

This adds a step named `flt`. Faultline takes your modules from your build: every module you register with `b.addModule`. These options are there when you want them: `.include` names the files and directories to fault test and `.exclude` names the files and directories to leave out, both as paths relative to your project root (see `USER-GUIDE.md` for examples).

Use `.exclude` for benchmarks and test harnesses. They are code, so Faultline takes them for source and asks you to cover their code paths too.

Build options: `-Dfile=<path>` and `-Dfunction=<name>` narrow Faultline to one file or one function, `-Dreport=<path>` moves the full checklist, `-Dkcov=<path>` names kcov, `-Dreplay="<token>"` reproduces a failure Faultline already reported and `-Djobs=<n>` sets how many workers run at once (one per processor core by default).

## 4. Run Faultline

```sh
zig build flt
```

Faultline exits 1 below 100% coverage and 0 at 100%.

Faultline keeps each file's result in your build's cache and does not execute again code that is unchanged since the run that proved it. The report says which files' results came from the cache. `zig build flt -- --no-cache` executes every file, and `zig build flt clear` throws the kept results away.

## 5. Read the report

```
  sizing.zig
    MISS isLarge                            2/3 code paths

  FAIL 1 code path that no call exercised:
      sizing.zig:9 "if:9:false" in isLarge: Faultline found no value that exercises this branch.

  One thing to do:
    Write a scenario exercising the false side of the if at sizing.zig:9 in isLarge.

  Coverage: 2 of 3 code paths, 66%.
```

A function is done when its line reads `ok`, which means every one of its code paths was exercised (the `2/3` in the example is 2 exercised out of 3). Each checklist line carries a file, a line and one thing to do. The report file named on the `Full detail` line lists every code path, exercised or not, every failure and every thing to do, including those the terminal leaves out.

## 6. Write value factories for your own types that Faultline cannot instantiate

A public function in the sim file that returns a value of one of those types. Faultline finds value factories by their return type and uses them only for the functions in the file beside the sim file. Put a factory several files need in `global.sim.zig`: Faultline uses its factories for every file. Write several, one per fault, to exercise the error handling.

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
```

## 7. Write a scenario for a code path Faultline cannot exercise

```zig
const sim = @import("sim");
const image = @import("image.zig");

pub fn runPngHeaderScenario(context: *sim.ScenarioContext) anyerror!void {
    const format = image.formatOf("PNG");
    try context.expect(@src(), format == .png, "PNG to be read as the png format");
}
```

Copy the parameter exactly and make the function `pub`. Faultline recognises a scenario by its parameter, `*sim.ScenarioContext`. The function can have any name. The context holds `faults`, `io`, `allocator` and `expect`.

## 8. Write an expectation function to check expectations after every call

```zig
pub fn rowsAndLinksAgree(context: *sim.ExpectationContext) anyerror!void {
    try context.expect(@src(), rows_match_links(context), "every row to have its link");
}
```

An expectation function runs after every call of a function in the matching source file and after every scenario in that sim file.

## Sim files

Value factories, scenarios and expectation functions go in a sim file beside the source: `image.sim.zig` for `image.zig`.

## How to write a value factory

- For a parameter that takes an error set, such as `anyerror`, a value factory returns the error itself (`pub fn missingFile() anyerror { return error.FileNotFound; }`). Faultline calls the function with an error of its own first and then with each factory's error.
- Re-exports are banned in `.sim.zig` files, including another sim file's value factory (`pub const name = other_sim.name;`).
- A value factory that returns a pointer, or a value holding pointers, creates what they point at with the allocator Faultline passes to it. Do not keep any of it in file-level variables or constants. Memory from that allocator lasts as long as the call.
- Put the value and everything it points at in one struct and create that with one `allocator.create`, rather than one `create` per piece.
- Build the value with the type's own constructor when it has one. Add a constructor only when building the value takes more than filling in its fields: a struct literal that only sets fields stays a struct literal.

## How to write a scenario

- When a value factory can exercise the code path, write the factory and not a scenario. Faultline calls the function with the factory's value and injects every failure into that call, which a scenario does not get.
- Once a type has a value factory in a sim file, Faultline uses only those factories for it in the functions of the file beside that sim file. Write one for every value it was exercised with before as well.
- Put the call on a line of its own and keep its result in a variable. Test the result in the expectation with `std.meta.isError(result)`, rather than writing `if (...) |_| ... else |err| ...` on one line.
