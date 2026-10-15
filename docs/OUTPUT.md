# What Faultline prints

Each example below shows the command and the exit code. `zig build flt` is the step `addFaultTest` adds to your build. These captures show the intended format and are replaced with captures of real output once the tool is built. Progress counts, elapsed time and per-function call counts and timings are left out.

Faultline ends with one number: the percentage of code paths exercised. The exit code is 0 only at 100%.

`<work directory>` stands for the directory in your build's cache where Faultline put everything it generated.

When there are many code paths no call exercised, the report gives the count and the file holding the full list instead of listing them all.

## 100% coverage

Every code path was exercised, so the last line reads 100% and Faultline exits 0.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

  Read 2 source files, with 3 functions to exercise.

  Found 2 source files, tested 1, exercised 3 functions and executed 9 of 9 code paths.
  Every call ran against a simulated filesystem and network, with every failure injected at every call that could fail that way.


  No call crashed, hung or found an expectation false.

  Coverage: 9 of 9 code paths, 100%.

  Every failure and every thing to do is in <cache>/faultline-report.txt.
```

Exit code: 0.

## A code path that no call exercised

Faultline found no input value and no value read from a condition in your source that exercises the branch. That is what a scenario is for.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

  Read 2 source files, with 1 function to exercise.

  Found 1 source file, tested 1, exercised 1 function and executed 2 of 3 code paths.
  Every call ran against a simulated filesystem and network, with every failure injected at every call that could fail that way.


  FAIL 1 code path that no call exercised:
      gateway.zig:18 "if:18:true" in opens: Faultline found no value that exercises this branch.

  One thing to do:
    Write a value factory that reaches the true side of the if at gateway.zig:18 in opens, or a scenario that exercises it if no value factory can.

  No call crashed, hung or found an expectation false.

  Coverage: 2 of 3 code paths, 66%.
  Failed: 1 code path of 3 was never exercised.
  The list above says what to do about each one.
  Took 0s.

  Every failure and every thing to do is in <cache>/faultline-report.txt.
```

Exit code: 1.

## A function that needs a value factory

A parameter whose type holds a function pointer cannot be built from its type, so the function is never called and none of its code paths can run. The line names the function, the type and what to write and that function's own code paths are left off the list: writing the factory is the whole of the work.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

  Read 2 source files, with 2 functions to exercise.

  Found 1 source file, tested 1, exercised 2 functions and executed 1 of 4 code paths.
  Every call ran against a simulated filesystem and network, with every failure injected at every call that could fail that way.


  FAIL 3 code paths that no call exercised:
      store.zig:15 "valueFor:entered" in valueFor: the function was never called.
      store.zig:17 "if:17:true" in valueFor: the function was never called.
      store.zig:20 "if:17:false" in valueFor: the function was never called.

  One thing to do:
    Write a value factory returning store.Store, which valueFor takes. Without one, valueFor at store.zig:15 cannot be called at all.

  No call crashed, hung or found an expectation false.

  Coverage: 1 of 4 code paths, 25%.
  Failed: 3 code paths of 4 were never exercised.
  The list above says what to do about each one.
  Took 0s.

  Every failure and every thing to do is in <cache>/faultline-report.txt.
```

Exit code: 1.

## A module that will not compile

Your code imports a module that your build does not register with `b.addModule`, so Faultline cannot build it. Faultline prints the compiler's own error and what to add to your build.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

Faultline could not compile your code. The compiler said:

uuid.zig:8:25: error: no module named 'shortid' available within module 'root'
const shortid = @import("shortid");

Supply the module shortid, which the code under test imports and Faultline had no path for. Register it in your build.zig with b.addModule.
```

Exit code: 1.

## kcov missing

kcov is required. If Faultline cannot find it, it prints one sentence and exits before it runs anything.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

Faultline needs kcov to see which lines ran and could not find it on the PATH. The install instructions are in docs/USER-GUIDE.md, under "Install kcov", or name it with -Dkcov=<path>.
```

Exit code: 1.

## A crash

Faultline shows where a call crashed: the file, line and column in the heading, what crashed and how, the failure Faultline injected, the declaration of the function Faultline called, each parameter with the value factory that filled it (with its file and line) or the value it was given, your code with a mark under the place and the stack trace from the command down to the panic, then a hint for that kind of crash. It finds the place by replaying the call once more with its stack trace, which only the crashes it shows pay for. When the panic is inside the standard library, it shows that line too, above the line of your code that called it, and a replay leaves out the `Reproduce it with:` line because the command is at the root of the stack trace.

```
-- CRASH ------------------------------------------------------------------ words.zig:9:51

firstWord in words.zig crashed: panic: attempt to unwrap error: OutOfMemory
Faultline made the 1st allocator call fail with "allocation fails", in allocBytesWithAlignment at std/mem/Allocator.zig:300.

Faultline called firstWord at words.zig:7:

5 | // The first word of the text, in memory of its own. The `catch unreachable` says an allocation
6 | // cannot fail, and Faultline injects the failure that proves it can.
7 | pub fn firstWord(allocator: std.mem.Allocator, text: []const u8) []u8 {
           ^

Called with:
    allocator = the allocator Faultline supplies
    text      = "a"

It panicked at words.zig:9:

7 | pub fn firstWord(allocator: std.mem.Allocator, text: []const u8) []u8 {
8 |     const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
9 |     return allocator.dupe(u8, text[0..end]) catch unreachable;
                                                      ^

Stack trace, from the command to the panic:
    zig build flt
    firstWord  words.zig:9:51  panicked here

Hint: This line treats an error as one that cannot happen, with `catch unreachable` or an `unreachable` arm, but it happened. Return it with `try`, or catch it and handle it.

Reproduce it with: zig build flt -Dreplay="<token>"
```

A run that replays crashes kept from earlier runs says so before its own calls, and each kept crash that still fails is shown like any other:

```
  Replayed 1 crash kept from earlier runs, and 1 of them still fails.
```

A kept crash that no longer names a call of the project is dropped with a line saying why:

```
  Dropped a kept crash, because the function or scenario it names is no longer in the project: words.zig:vanished;seed=2920345936653814948;values=b0,b1;fail=allocator#0/allocation_fails
```

## A scenario whose expectation failed

Faultline says which scenario wrote the expectation, what it expected and the line it is on, then stops.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

  Read 2 source files, with 1 function to exercise.
The scenario runAddingUpScenario expected the total to be twice the amount it was given, at total.sim.zig:18.
Reproduce it with: zig build flt -Dreplay="<token>"
Faultline stopped with ExpectationFailed.
```

Exit code: 1.

## An expectation function that failed

Faultline says which expectation function failed, after which call or scenario, what it expected and the line, then prints the replay command.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

  Read 2 source files, with 1 function to exercise.
The expectation function totalIsNeverNegative expected the total to stay at or above zero, at total.sim.zig:9, after the call to addAmount with an allocation failure injected at its first allocation.
Reproduce it with: zig build flt -Dreplay="<token>"
Faultline stopped with ExpectationFailed.
```

Exit code: 1.

## Below 100% coverage

The percentage on the last line is the whole verdict: below a hundred Faultline exits 1, whatever else it printed.

```sh
$ zig build flt
```

```
Fault testing the Zig source in this directory.

  Read 2 source files, with 1 function to exercise.

  Found 1 source file, tested 1, exercised 1 function and executed 6 of 7 code paths.
  Every call ran against a simulated filesystem and network, with every failure injected at every call that could fail that way.


  FAIL 1 code path that no call exercised:
      rounding.zig:23 "if:23:true" in upTo: Faultline found no value that exercises this branch.

  One thing to do:
    Write a value factory that reaches the true side of the if at rounding.zig:23 in upTo, or a scenario that exercises it if no value factory can.

  No call crashed, hung or found an expectation false.

  Coverage: 6 of 7 code paths, 85%.
  Failed: 1 code path of 7 was never exercised.
  The list above says what to do about each one.
  Took 0s.

  Every failure and every thing to do is in <cache>/faultline-report.txt.
```

Exit code: 1.

## Replaying a failure

A replay drives exactly the plan the token holds: the failures it injects and the values it chose.

```sh
$ zig build flt -Dreplay="<token>"
```

```
Fault testing the Zig source in this directory.
The replay of "<token>" passed.
```

Exit code: 0.
