# A module the project registers

`storing.zig` imports `units` by name. `build.zig` registers that module with `b.addModule`, and the build step hands every registered module to the program, so the import resolves. A module made with `b.createModule` is not registered and cannot be seen.
