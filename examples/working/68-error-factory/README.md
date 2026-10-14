# A value factory for an error

`describe` takes `anyerror` and words each error it knows. Faultline hands an error parameter one error of its own, which reaches only the `else` arm. The value factories in `wording.sim.zig` return the other errors, and Faultline calls `describe` with each of them as well, so every arm is exercised.
