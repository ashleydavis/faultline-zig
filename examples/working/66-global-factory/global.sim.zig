// The value factories for `Store`, which every file that takes one is called with, because they
// are in `global.sim.zig`.
//
// One store finds every key and one finds none, so both sides of each `if` are exercised.

const store_mod = @import("store.zig");

// Answers every key with the same value. The context is not used, so it points at nothing.
fn findEverything(_: *anyopaque, _: []const u8) ?[]const u8 {
    return "found";
}

// Answers no key.
fn findNothing(_: *anyopaque, _: []const u8) ?[]const u8 {
    return null;
}

// What every store here is given as its context, because none of them reads it.
var no_state: u8 = 0;

// Builds a `Store` that finds every key. Faultline finds it by its return type.
pub fn storeThatFindsEverything() store_mod.Store {
    return .{ .ctx = &no_state, .read = findEverything };
}

// Builds a `Store` that finds no key.
pub fn storeThatFindsNothing() store_mod.Store {
    return .{ .ctx = &no_state, .read = findNothing };
}
