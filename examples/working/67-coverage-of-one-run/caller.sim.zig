// The value factories for `Table`, used for `caller.zig` only.
//
// One table finds every key and one finds none, so both sides of `lookup.find`'s `if` run when
// `caller.zig` calls it.

const lookup = @import("lookup.zig");

// Answers every key with the same value. The context is not used.
fn findEverything(_: *anyopaque, _: []const u8) ?[]const u8 {
    return "found";
}

// Answers no key.
fn findNothing(_: *anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

// What every table here is given as its context, because none of them reads it.
var no_state: u8 = 0;

// Builds a `Table` that finds every key.
pub fn tableThatFindsEverything() lookup.Table {
    return .{ .ctx = &no_state, .read = findEverything };
}

// Builds a `Table` that finds no key.
pub fn tableThatFindsNothing() lookup.Table {
    return .{ .ctx = &no_state, .read = findNothing };
}
