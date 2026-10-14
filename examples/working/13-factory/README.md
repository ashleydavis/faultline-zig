# A value factory for a type Faultline cannot instantiate

`Store` holds a function pointer, which Faultline cannot instantiate. `store.sim.zig` has two value factories that return a `Store`, one that finds every key and one that finds none. Faultline calls `valueFor` with each, so both sides of its `if` are exercised.
