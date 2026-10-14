// The test root for the files that say where an effect can fail: the effects, the points, the table
// of failures and the injector.

test {
    _ = @import("point.zig");
    _ = @import("failures.zig");
    _ = @import("injector.zig");
}
