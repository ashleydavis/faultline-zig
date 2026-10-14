// The replay token: everything needed to repeat one function's calls, as text a person can copy
// from a failure message into `-Dreplay`.
//
// It holds which function, the seed the run's random numbers started from, the value chosen for
// each parameter, and the failures injected. Nothing else is needed to replay: no environment, no
// log and no leftover state.
//
// Written as `<file>:<function>;seed=<n>;values=<choices>;fail=<failures>`. A choice is a letter
// for where the value came from (`b` boundary, `s` seeded, `c` condition, `f` factory) and its
// index. A failure is `<effect>#<occurrence>/<failure id>`. Several choices or failures are
// separated by commas. A part with nothing in it is left out.

const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector = @import("injector.zig");
const call_specs = @import("call_specs.zig");

// Where a chosen value came from, and which value from there. The same types the value chooser
// lists and builds from, so a token carries exactly what the chooser needs to build the value
// again.
pub const Source = call_specs.Source;
pub const Choice = call_specs.Choice;

// The letter a token uses for where a value came from.
fn letterOf(source: Source) u8 {
    return switch (source) {
        .boundary => 'b',
        .seeded => 's',
        .condition => 'c',
        .factory => 'f',
    };
}

// The source a token's letter names.
fn sourceOf(character: u8) ?Source {
    return switch (character) {
        'b' => .boundary,
        's' => .seeded,
        'c' => .condition,
        'f' => .factory,
        else => null,
    };
}

// What can be wrong with a token.
pub const ParseError = error{
    NoFunction,
    BadPart,
    BadSeed,
    BadChoice,
    BadFailure,
    UnknownEffect,
    UnknownFailure,
    OutOfMemory,
};

pub const Plan = struct {
    // The source file the function is in, relative to the project root.
    file: []const u8,

    // The function, as `name` or `Owner.name` for a method.
    function: []const u8,

    // The seed the random number generator started from.
    seed: u64,

    // The value chosen for each parameter, in order.
    choices: []const Choice,

    // The failures to inject.
    injections: []const injector.Injection,

    // The memory behind the slices above when the plan was read from text. Null for a plan built
    // in code, whose slices the builder owns.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Plan) void {
        if (self.arena) |*arena| {
            arena.deinit();
        }
        self.arena = null;
    }

    // Whether two plans name the same calls.
    pub fn eql(self: Plan, other: Plan) bool {
        if (!std.mem.eql(u8, self.file, other.file) or !std.mem.eql(u8, self.function, other.function)) {
            return false;
        }
        if (self.seed != other.seed or self.choices.len != other.choices.len or self.injections.len != other.injections.len) {
            return false;
        }
        for (self.choices, other.choices) |a, b| {
            if (a.source != b.source or a.index != b.index) {
                return false;
            }
        }
        for (self.injections, other.injections) |a, b| {
            if (!a.point.eql(b.point) or a.kind != b.kind) {
                return false;
            }
        }
        return true;
    }

    // Writes the token.
    pub fn format(self: Plan, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}:{s};seed={d}", .{ self.file, self.function, self.seed });
        if (self.choices.len != 0) {
            try writer.writeAll(";values=");
            for (self.choices, 0..) |choice, index| {
                if (index != 0) {
                    try writer.writeByte(',');
                }
                try writer.print("{c}{d}", .{ letterOf(choice.source), choice.index });
            }
        }
        if (self.injections.len != 0) {
            try writer.writeAll(";fail=");
            for (self.injections, 0..) |injection, index| {
                if (index != 0) {
                    try writer.writeByte(',');
                }
                try writer.print("{s}#{d}/{s}", .{
                    @tagName(injection.point.effect),
                    injection.point.occurrence,
                    injector.Injector.nameOf(injection),
                });
            }
        }
    }
};

// Reads a token. The plan owns what it points at and `deinit` releases it.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const room = arena.allocator();

    var parts = std.mem.splitScalar(u8, text, ';');
    const head = parts.next() orelse return error.NoFunction;
    const colon = std.mem.lastIndexOfScalar(u8, head, ':') orelse return error.NoFunction;
    if (colon == 0 or colon + 1 >= head.len) {
        return error.NoFunction;
    }

    var plan: Plan = .{
        .file = try room.dupe(u8, head[0..colon]),
        .function = try room.dupe(u8, head[colon + 1 ..]),
        .seed = 0,
        .choices = &.{},
        .injections = &.{},
    };

    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "seed=")) {
            plan.seed = std.fmt.parseInt(u64, part["seed=".len..], 10) catch return error.BadSeed;
        } else if (std.mem.startsWith(u8, part, "values=")) {
            plan.choices = try parseChoices(room, part["values=".len..]);
        } else if (std.mem.startsWith(u8, part, "fail=")) {
            plan.injections = try parseInjections(room, part["fail=".len..]);
        } else {
            return error.BadPart;
        }
    }

    plan.arena = arena;
    return plan;
}

fn parseChoices(room: std.mem.Allocator, text: []const u8) ParseError![]const Choice {
    var choices: std.ArrayList(Choice) = .empty;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        if (item.len < 2) {
            return error.BadChoice;
        }
        const source = sourceOf(item[0]) orelse return error.BadChoice;
        const index = std.fmt.parseInt(u32, item[1..], 10) catch return error.BadChoice;
        try choices.append(room, .{ .source = source, .index = index });
    }
    return choices.toOwnedSlice(room);
}

fn parseInjections(room: std.mem.Allocator, text: []const u8) ParseError![]const injector.Injection {
    var list: std.ArrayList(injector.Injection) = .empty;
    var items = std.mem.splitScalar(u8, text, ',');
    while (items.next()) |item| {
        const hash = std.mem.indexOfScalar(u8, item, '#') orelse return error.BadFailure;
        const slash = std.mem.indexOfScalarPos(u8, item, hash, '/') orelse return error.BadFailure;
        const effect = std.meta.stringToEnum(point.Effect, item[0..hash]) orelse return error.UnknownEffect;
        const occurrence = std.fmt.parseInt(u32, item[hash + 1 .. slash], 10) catch return error.BadFailure;
        const id = item[slash + 1 ..];

        var found: ?u8 = null;
        for (failures.kindsOf(effect), 0..) |kind, index| {
            if (std.mem.eql(u8, kind.id, id)) {
                found = @intCast(index);
                break;
            }
        }
        const kind = found orelse return error.UnknownFailure;
        try list.append(room, .{ .point = .{ .effect = effect, .occurrence = occurrence }, .kind = kind });
    }
    return list.toOwnedSlice(room);
}

test {
    _ = @import("plan.test.zig");
}
