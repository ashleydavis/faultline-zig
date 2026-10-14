// The state the simulated effects share: the injector they ask, the `Io` they sit on top of and
// the helpers that turn a failure's id in `docs/FAILURES.md` into the index the injector speaks.
//
// This is module-level state on purpose. The vtable entries of `std.Io` receive only an opaque
// pointer that belongs to the implementation they are layered over, so the simulated world has
// nowhere else to keep what it knows. Each call of the function under test runs in a fresh child
// process and `reset` gives unit tests and in-process use the same clean start.

const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector_mod = @import("injector.zig");

// The injector every effect asks. Null means no injector is installed, so nothing fails and nothing
// is recorded.
pub var injector: ?*injector_mod.Injector = null;

// The `Io` the simulated entries sit on. Calls that are not about the simulated world, such as a
// socket this module did not create, are handed to it.
pub var underneath: std.Io = undefined;

// The `Io` that has the simulated entries in it. Entries that need to call back through `Io` (a
// queue put, for example) use it so their own work goes through the same layering.
pub var own: std.Io = undefined;

// Handles this world hands out start here and count up. A real file descriptor is a small number,
// so a handle at or above this value is never a real one, which is how an entry tells its own
// sockets and children from the ones it must pass on. The value is below the largest 32-bit
// signed integer with room for a billion handles.
pub const first_handle: i32 = 1_000_000_000;

// Remembers where the simulated entries are layered and clears everything the effects hold.
pub fn attach(under: std.Io, with_entries: std.Io, asked: *injector_mod.Injector) void {
    underneath = under;
    own = with_entries;
    injector = asked;
}

// Asks the injector once about the call that is happening. Returns the index of the failure to
// inject or null. With no injector installed nothing fails.
pub fn ask(effect: point.Effect, kinds: []const u8) ?u8 {
    const asked = injector orelse {
        return null;
    };
    return asked.check(effect, kinds);
}

// The index of the failure whose id is `id` in the table of `effect`. Evaluated while compiling, so
// a misspelt id is a compile error and a row renamed in `failures.zig` cannot be missed here.
pub fn kindIndex(comptime effect: point.Effect, comptime id: []const u8) u8 {
    const found: ?u8 = comptime find: {
        for (failures.kindsOf(effect), 0..) |kind, index| {
            if (std.mem.eql(u8, kind.id, id)) {
                break :find index;
            }
        }
        break :find null;
    };
    return found orelse @compileError("faultline: no failure with the id " ++ id ++ " in the table of " ++ @tagName(effect));
}

// Whether the failure the injector returned is the row `id`.
pub fn isKind(comptime effect: point.Effect, comptime id: []const u8, chosen: u8) bool {
    return chosen == kindIndex(effect, id);
}

// Builds the array of indexes for the rows `ids` of `effect`, for the `kinds` argument of `ask`.
pub fn kindsFor(comptime effect: point.Effect, comptime ids: []const []const u8) [ids.len]u8 {
    var indexes: [ids.len]u8 = undefined;
    inline for (ids, 0..) |id, position| {
        indexes[position] = kindIndex(effect, id);
    }
    return indexes;
}

test {
    _ = @import("effect_state.test.zig");
}
