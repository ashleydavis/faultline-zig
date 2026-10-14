# A project that names where its code is

The code is under `lib/text`, and `build.zig` names it with `.include`. Naming `.include` turns off the search of the whole project, so `scripts/generate.zig` is left alone. Example 24 shows the search that runs when `.include` is absent.
