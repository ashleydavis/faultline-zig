# A value factory in another file's sim file

`store.sim.zig` has value factories for `Store`, so Faultline calls `valueFor` in `store.zig`. `reader.zig` also takes a `Store`, but Faultline uses a sim file's value factories only for the file beside it, so `firstOf` is never called and the report asks for a value factory that returns a `Store`. A factory for it in `reader.sim.zig` would let Faultline call `firstOf`.
