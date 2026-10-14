# Coverage comes from one run only

`lookup.find` takes a `Table`, which Faultline cannot instantiate, and `lookup.sim.zig` does not exist, so Faultline never calls `find` itself. `caller.nameIn` calls it with the tables in `caller.sim.zig`, so a run of the whole project exercises every code path of `find`. The smoke script also runs `caller.zig` alone and then `lookup.zig` alone, and checks that the second run reports `find` as never called: coverage from the first run is not carried into the next.
