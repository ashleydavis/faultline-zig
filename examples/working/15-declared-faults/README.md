# One value factory per fault

`reader.sim.zig` has a value factory for a working `Source` and one for each way a source breaks. Faultline calls `firstByte` with each of them, so the code that handles each fault is exercised.
