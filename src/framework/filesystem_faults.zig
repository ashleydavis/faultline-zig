// How the simulated filesystem asks the injector whether a call fails and turns the answer into
// the error the failure table says that call returns.
//
// The table in `docs/FAILURES.md` is code in `failures.zig`. A row names its error in the "What the
// call returns" column, so this file reads the error name out of that text and a call site only
// lists the ids of the rows that can happen to it. That keeps the error a call returns and the
// table from drifting apart.

const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector_mod = @import("injector.zig");

// The injector every simulated call asks. Null until `install` hands one over and a null injector
// fails nothing, so a scenario can build its tree with the helpers before the world is installed.
pub var injector: ?*injector_mod.Injector = null;

// The index of the row with `id` in the table for `effect`, known while compiling so a misspelt id
// is a compile error and not a failure that never happens.
pub fn indexOf(comptime effect: point.Effect, comptime id: []const u8) u8 {
    const kinds = comptime failures.kindsOf(effect);
    inline for (kinds, 0..) |kind, index| {
        if (comptime std.mem.eql(u8, kind.id, id)) {
            return index;
        }
    }
    @compileError("no failure with id '" ++ id ++ "' in the table for " ++ @tagName(effect));
}

// Whether the failure picked by the injector is the row `id`.
pub fn isKind(comptime effect: point.Effect, comptime id: []const u8, picked: u8) bool {
    return picked == comptime indexOf(effect, id);
}

// The error named at the start of a row's "What the call returns" text, or null when the text
// describes something that is not an error (a short read, a try-lock that returns false).
fn errorNameOf(comptime kind: failures.Kind) ?[]const u8 {
    const prefix = "error.";
    if (!std.mem.startsWith(u8, kind.returns, prefix)) {
        return null;
    }
    var end: usize = prefix.len;
    while (end < kind.returns.len and std.ascii.isAlphanumeric(kind.returns[end])) {
        end += 1;
    }
    return kind.returns[prefix.len..end];
}

// Whether the error set `Set` has an error called `name`.
pub fn hasError(comptime Set: type, comptime name: []const u8) bool {
    const errors = @typeInfo(Set).error_set orelse return true;
    inline for (errors) |one| {
        if (comptime std.mem.eql(u8, one.name, name)) {
            return true;
        }
    }
    return false;
}

// The error a row stands for in `Set`. A call whose error set has no `InputOutput` reports it as
// `Unexpected`, which is what Zig's own implementation does when the operating system answers a
// read, a listing or a stat with an input or output error. Null when the call cannot return it.
fn errorNameIn(comptime effect: point.Effect, comptime Set: type, comptime id: []const u8) ?[]const u8 {
    const kind = failures.kindsOf(effect)[indexOf(effect, id)];
    const name = errorNameOf(kind) orelse return null;
    if (hasError(Set, name)) {
        return name;
    }
    if (std.mem.eql(u8, name, "InputOutput") and hasError(Set, "Unexpected")) {
        return "Unexpected";
    }

    // A writer reports every failure of the call under it as `WriteFailed`. The call under it
    // reports an output that has been closed as `BrokenPipe` and that is what becomes `WriteFailed`.
    if (std.mem.eql(u8, name, "WriteFailed") and hasError(Set, "BrokenPipe")) {
        return "BrokenPipe";
    }

    // A write has no word for a filesystem that is read-only, because that is refused when the
    // file is opened. The nearest word a write has is that the handle does not have the right.
    if (std.mem.eql(u8, name, "ReadOnlyFileSystem") and hasError(Set, "AccessDenied")) {
        return "AccessDenied";
    }
    return null;
}

// How much comptime work the table lookups need. The table has a few hundred rows and each call
// site looks through it for every id it lists, so the default limit is too low.
const eval_quota: u32 = 1_000_000;

// What one call site offers the injector: the rows of `ids` that can happen to a call whose error
// set is `Set`, which is every row that is not an error and every error row whose error the call
// can return. A type so each combination is worked out once and its storage is static, because the
// injector keeps the slice it is given.
fn Offer(comptime effect: point.Effect, comptime Set: type, comptime ids: []const []const u8) type {
    return struct {
        // The ids kept, in the order the call site listed them.
        pub const kept: []const []const u8 = blk: {
            @setEvalBranchQuota(eval_quota);
            var out: []const []const u8 = &.{};
            for (ids) |id| {
                const kind = failures.kindsOf(effect)[indexOf(effect, id)];
                if (errorNameOf(kind) == null or errorNameIn(effect, Set, id) != null) {
                    out = out ++ [_][]const u8{id};
                }
            }
            break :blk out;
        };

        // The indexes into the effect's table of the ids kept.
        pub const list: [kept.len]u8 = blk: {
            @setEvalBranchQuota(eval_quota);
            var out: [kept.len]u8 = undefined;
            for (kept, 0..) |id, at| {
                out[at] = indexOf(effect, id);
            }
            break :blk out;
        };
    };
}

// Asks the injector once about a call that can fail in the ways `ids` lists, dropping the rows the
// error set `Set` cannot express. Returns the index of the failure to inject, or null to go ahead.
// A call none of the rows can happen to does not ask.
pub fn ask(comptime effect: point.Effect, comptime Set: type, comptime ids: []const []const u8) ?u8 {
    const offer = Offer(effect, Set, ids);
    if (offer.list.len == 0) {
        return null;
    }
    const active = injector orelse return null;
    return active.check(effect, &offer.list);
}

// The error to return for the failure the injector picked. Only valid for a row whose text names an
// error and which the call asked about.
pub fn errorOf(comptime effect: point.Effect, comptime Set: type, picked: u8) Set {
    @setEvalBranchQuota(eval_quota);
    const kinds = comptime failures.kindsOf(effect);
    inline for (kinds, 0..) |kind, index| {
        if (comptime errorNameIn(effect, Set, kind.id)) |name| {
            if (picked == index) {
                return @field(Set, name);
            }
        }
    }
    unreachable;
}

// Asks about a call whose every failure is an error and returns the error to give back, or null to
// go ahead.
pub fn failWith(comptime effect: point.Effect, comptime Set: type, comptime ids: []const []const u8) ?Set {
    const picked = ask(effect, Set, ids) orelse return null;
    return errorOf(effect, Set, picked);
}

test {
    _ = @import("filesystem_faults.test.zig");
}
