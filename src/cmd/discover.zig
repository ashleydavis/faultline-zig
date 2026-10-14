// The test root for discovery: finding which files to fault test and what each one offers. The
// parts are in files of their own and this file pulls their tests in.
//
// - `walk.zig`: the one walk over a project and the report of what it took and skipped.
// - `skip_rules.zig`: the rules the walk asks and the reason for each skip.
// - `uncallable.zig`: functions that cannot be called and what stopped each.
// - `conditions.zig`: the conditions in a function, read with `std.zig.Ast`.
// - `finders.zig`: value factories, scenarios and expectation functions in a sim file.

test {
    _ = @import("walk.zig");
    _ = @import("skip_rules.zig");
    _ = @import("uncallable.zig");
    _ = @import("conditions.zig");
    _ = @import("finders.zig");
}
