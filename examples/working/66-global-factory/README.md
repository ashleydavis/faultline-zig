# A value factory in global.sim.zig

`store.zig` and `reader.zig` both take a `Store`. Its value factories are in `global.sim.zig`, which Faultline uses for every file, so both `valueFor` and `firstOf` are called and every code path is exercised.
