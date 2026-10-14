# A module the build did not register

`uuid.zig` imports `shortid`, and `build.zig` never registers a module of that name with `b.addModule`. The program cannot be built, so the compiler error is printed and Faultline exits 1.
