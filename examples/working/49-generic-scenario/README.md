# A generic function called by a scenario

`first` takes a type parameter, so Faultline cannot call it on its own. `lists.sim.zig` has a scenario that calls it with bytes, which exercises both of its code paths.
