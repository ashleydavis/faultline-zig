# CLAUDE.md

Instructions for an agent working in this repository. This doc is not for humans. Use one line per rule. Never pad this file or add unnecessary filler.

## The toolchain

Install it with `mise install`, then type every command in `docs/DEVELOPMENT.md` as it is written, through `mise exec --` from the directory that holds `mise.toml`.

## Vocabulary

Use these terms consistently in code, docs and output.

- Value factory: a function in a `.sim.zig` file that builds a value of one of your own types that Faultline cannot instantiate.
- Fault testing: Faultline's own calls with chosen inputs and injected failures.
- Fault testing scenario, or scenario: a function you write that calls your code with chosen inputs. It takes `*sim.ScenarioContext`.
- Expectation function: a function that checks expectations after a call or a scenario. It takes `*sim.ExpectationContext`.

## Tests

Every function must be comprehensively covered by automated tests.

Put every test in `<name>.test.zig` beside the source, never in a `test` block inside the source file and name it from that source file's own `test` block with `_ = @import("<name>.test.zig");` or it never runs.

Never skip, disable or weaken a test.

Run the narrowest suite that covers your change first, then `bash scripts/test-everything.sh` before committing.

## The hook

Run `bash scripts/install-hooks.sh` in every fresh clone before committing.

Never bypass or edit the pre-commit hook, or the scripts it calls. When it refuses a commit, fix what failed and commit again.

## Commits

The subject line says what was done. The description says why, what was tried and rejected and any measurement with the conditions it was taken under. Never restate the diff in prose.

Update the documentation in the same commit as the change it describes.

## Writing

Every message the tool prints reads as a proper sentence: a capital letter at the start and a full stop at the end.

Print one checklist line per thing the user has to do, each a sentence carrying the file and line: write a scenario, write a value factory for a type Faultline cannot instantiate, supply a module.

Write one line per paragraph or bullet, with no hard wrapping, no `---` rules and no em dashes.

No jargon, no filler, no made up examples.

Never hard-code a count that changes into docs or comments. Say what it is derived from.

Never commit an absolute path, a secret or a personal detail.

Never use these words: "shape"; "gate", "gated", "gating", "ungated"; "exploration"; credibility framing such as "honestly", "frankly", "clearly", "actually" and "plainly"; and meaningless causes for a mistake such as "habit", "instinct", "reflex" and "muscle memory".

Never write "nothing" or "nobody" in the documentation. Name the thing that is absent: "no value factory", "no call exercised it", "no list refers to it".

## Code

Write Zig for the tool and shell for the scripts and nothing else.

Give every shell script `#!/usr/bin/env bash`, a `.sh` extension, `bash -n` run over it and usage printed when it is run with no arguments.

Never write source code inside strings in the tool's own code. The one exception is the table of `@import` lines the build step writes into the build's cache for the project's own files, because Zig reads an import path only from a string literal in source. That table holds data and no logic.

Comment every global symbol and every struct field.

Write beside every named constant why its value is what it is.

Use 4-space indentation, braces on the same line and `else` and `catch` on a new line.

Never write an `if` or an `else` without braces. Every body goes on its own lines, whatever it does and however short it is: a bare `continue`, a `return`, a `break`.

Inject failures systematically from what coverage has not exercised. Never choose a failure at random. Record the random number generator's seed in the replay token so a replay can set it.

## The contract

`docs/CONTRACT.md` is the human's. Never edit it and never add to it, unless the human asks for that change in the message you are acting on.

Told to make the code match it, change the code. Editing the contract to describe what the code does inverts the one line at the top of it, which says the file is right and the behaviour is the defect.

Where the code cannot meet it, say so and stop. Do not write an exemption into it and never record that the human asked for something they did not.

## Naming

Name a function that does something as a verb and what it does it to: `printTallies`, `readSources`, `writeRoot`.

Name a function that answers yes or no with `is`, `has` or `was`: `isHarness`, `hasExcludedPrefix`.

Name a function that only works something out after what it returns: `pathCounts`, `sourceDirectories`.

Never say `say` when you mean `print`, `get` when you mean `read`, or `handle` when you mean anything at all.

Never end a name in a preposition unless the call site reads as English: `percentageOf(ticked, total)` reads; `exitStatusFor(err)` does not.

A name that needs `and` in it is two functions. Split it and the two names come out on their own.

A name is wrong when the comment above it says something the name could have: if the comment starts by correcting the name, rename it.
