const std = @import("std");
const auto = @import("auto.zig");
const condition = @import("condition.zig");
const locator = @import("locator.zig");

const Choice = auto.Choice;

// A locator over a namespace with no factories, for the cases about building a value from its own
// type. A sim file with nothing in it.
const NoFactories = locator.Locator(struct {});

// Everything a context needs, held in one place so a test can start and finish one in two lines.
fn Harness(comptime Locator: type) type {
    return struct {
        const Self = @This();

        arena_state: std.heap.ArenaAllocator,
        factories: Locator,
        prng: std.Random.Xoshiro256,
        paper: [64]u8,
        writer: std.Io.Writer,
        seed: u64,
        conditions: []const condition.Condition,

        fn start(self: *Self, seed: u64) void {
            self.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            self.factories = Locator.init();
            self.prng = std.Random.Xoshiro256.init(1);
            self.writer = std.Io.Writer.fixed(&self.paper);
            self.seed = seed;
            self.conditions = &.{};
        }

        fn finish(self: *Self) void {
            self.arena_state.deinit();
        }

        fn context(self: *Self) auto.Context(Locator) {
            return .{
                .locator = &self.factories,
                .arena = self.arena_state.allocator(),
                .call_allocator = self.arena_state.allocator(),
                .io = std.Io.failing,
                .random = self.prng.random(),
                .writer = &self.writer,
                .seed = self.seed,
                .conditions = self.conditions,
            };
        }
    };
}

const Plain = Harness(NoFactories);

fn boundaryChoice(index: u32) Choice {
    return .{ .source = .boundary, .index = index };
}

fn seededChoice(index: u32) Choice {
    return .{ .source = .seeded, .index = index };
}

fn conditionChoice(index: u32) Choice {
    return .{ .source = .condition, .index = index };
}

// How many of the choices come from a source.
fn countFrom(choices: []const Choice, source: auto.Source) usize {
    var total: usize = 0;
    for (choices) |choice| {
        if (choice.source == source) {
            total += 1;
        }
    }
    return total;
}

fn comparison(literal: condition.Literal) condition.Condition {
    return .{ .line = 1, .kind = .comparison, .operator = .greater, .literal = literal, .subject = "value" };
}

test "canMakeValue accepts the types a run can build and refuses the ones it cannot" {
    try std.testing.expect(comptime auto.canMakeValue(u32, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(f64, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(bool, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(void, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue([]const u8, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue([:0]const u8, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(?u8, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue([4]u8, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(*u8, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(std.mem.Allocator, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(std.Io, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(std.Random, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(*std.Io.Writer, NoFactories));

    // An error set is handed whole, never built from parts.
    try std.testing.expect(comptime auto.canMakeValue(anyerror, NoFactories));
    try std.testing.expect(comptime auto.canMakeValue(error{Broken}, NoFactories));
    try std.testing.expect(!(comptime auto.canMakeValue(error{}, NoFactories)));

    // A bare function pointer points nowhere useful and an erased pointer has no type to build.
    try std.testing.expect(!(comptime auto.canMakeValue(*const fn () void, NoFactories)));
    try std.testing.expect(!(comptime auto.canMakeValue(*anyopaque, NoFactories)));
    try std.testing.expect(!(comptime auto.canMakeValue([*]u8, NoFactories)));
    try std.testing.expect(!(comptime auto.canMakeValue(enum {}, NoFactories)));
}

test "a tagged union is buildable when one of its variants is and untagged never is" {
    const Mixed = union(enum) {
        ordinary: u32,
        opaque_pointer: *anyopaque,
    };
    try std.testing.expect(comptime auto.canMakeValue(Mixed, NoFactories));

    const OnlyOpaque = union(enum) { opaque_pointer: *anyopaque };
    try std.testing.expect(!(comptime auto.canMakeValue(OnlyOpaque, NoFactories)));

    const Untagged = union { a: u32, b: f32 };
    try std.testing.expect(!(comptime auto.canMakeValue(Untagged, NoFactories)));
}

test "a struct is buildable when every field that is built can be and a field with a default is left alone" {
    const Wholesome = struct { a: u8, b: ?bool, c: []const u8 };
    try std.testing.expect(comptime auto.canMakeValue(Wholesome, NoFactories));

    const Unbuildable = struct { a: u8, callback: *const fn () void };
    try std.testing.expect(!(comptime auto.canMakeValue(Unbuildable, NoFactories)));

    const Defaulted = struct { a: u8, callback: *const fn () void = &noop };
    try std.testing.expect(comptime auto.canMakeValue(Defaulted, NoFactories));

    const External = extern struct { a: u8 };
    try std.testing.expect(!(comptime auto.canMakeValue(External, NoFactories)));
}

fn noop() void {}

test "a type that holds itself has no bottom and is refused" {
    const Node = struct { next: ?*@This() };
    try std.testing.expect(!(comptime auto.canMakeValue(Node, NoFactories)));
}

// A sim file with a factory for a type that cannot be built from its own type.
const SourceSim = struct {
    pub const Reader = struct {
        read: *const fn () u8,
    };

    pub fn workingReader() Reader {
        return .{ .read = &readOne };
    }

    pub fn brokenReader() Reader {
        return .{ .read = &readZero };
    }

    pub fn nothingCommon() u32 {
        return 4242;
    }

    fn readOne() u8 {
        return 1;
    }

    fn readZero() u8 {
        return 0;
    }
};
const WithReader = locator.Locator(SourceSim);

test "a type only a value factory can build is buildable, alone and inside another type" {
    try std.testing.expect(comptime auto.canMakeValue(SourceSim.Reader, WithReader));
    try std.testing.expect(!(comptime auto.canMakeValue(SourceSim.Reader, NoFactories)));
    const Holder = struct { reader: SourceSim.Reader, limit: u8 };
    try std.testing.expect(comptime auto.canMakeValue(Holder, WithReader));
    try std.testing.expect(!(comptime auto.canMakeValue(Holder, NoFactories)));
    try std.testing.expect(comptime auto.canMakeValue(?SourceSim.Reader, WithReader));
    try std.testing.expect(comptime auto.canMakeValue([]const SourceSim.Reader, WithReader));
}

test "the boundary choices of an unsigned integer build zero, one and the maximum" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    try std.testing.expectEqual(@as(u8, 0), try auto.buildValue(u8, NoFactories, ctx, boundaryChoice(0)));
    try std.testing.expectEqual(@as(u8, 1), try auto.buildValue(u8, NoFactories, ctx, boundaryChoice(1)));
    try std.testing.expectEqual(@as(u8, 255), try auto.buildValue(u8, NoFactories, ctx, boundaryChoice(2)));
}

test "the boundary choices of a signed integer build zero, one, minus one, minimum and maximum" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const expected = [_]i16{ 0, 1, -1, std.math.minInt(i16), std.math.maxInt(i16) };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, try auto.buildValue(i16, NoFactories, ctx, boundaryChoice(@intCast(index))));
    }
}

test "the boundary choices of a float, a bool and an enum" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    try std.testing.expectEqual(@as(f64, 0), try auto.buildValue(f64, NoFactories, ctx, boundaryChoice(0)));
    try std.testing.expectEqual(@as(f64, -1), try auto.buildValue(f64, NoFactories, ctx, boundaryChoice(2)));
    try std.testing.expectEqual(false, try auto.buildValue(bool, NoFactories, ctx, boundaryChoice(0)));
    try std.testing.expectEqual(true, try auto.buildValue(bool, NoFactories, ctx, boundaryChoice(1)));

    const Colour = enum { red, green, blue };
    try std.testing.expectEqual(Colour.red, try auto.buildValue(Colour, NoFactories, ctx, boundaryChoice(0)));
    try std.testing.expectEqual(Colour.green, try auto.buildValue(Colour, NoFactories, ctx, boundaryChoice(1)));
    try std.testing.expectEqual(Colour.blue, try auto.buildValue(Colour, NoFactories, ctx, boundaryChoice(2)));
}

test "every enum tag is offered as a choice" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const Colour = enum { red, green, blue };
    const choices = try auto.listChoices(Colour, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 3), countFrom(choices, .boundary));
    var seen = [_]bool{ false, false, false };
    for (choices) |choice| {
        const value = try auto.buildValue(Colour, NoFactories, h.context(), choice);
        seen[@intFromEnum(value)] = true;
    }
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &seen);
}

test "an optional offers null then a value" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    try std.testing.expectEqual(@as(?u8, null), try auto.buildValue(?u8, NoFactories, ctx, boundaryChoice(0)));
    try std.testing.expectEqual(@as(?u8, 0), try auto.buildValue(?u8, NoFactories, ctx, boundaryChoice(1)));
    try std.testing.expectEqual(@as(?u8, 1), try auto.buildValue(?u8, NoFactories, ctx, boundaryChoice(2)));
    try std.testing.expectEqual(@as(?u8, 255), try auto.buildValue(?u8, NoFactories, ctx, boundaryChoice(3)));
}

test "a string offers the empty string and a one character string" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    try std.testing.expectEqualStrings("", try auto.buildValue([]const u8, NoFactories, ctx, boundaryChoice(0)));
    const second = try auto.buildValue([]const u8, NoFactories, ctx, boundaryChoice(1));
    try std.testing.expectEqual(@as(usize, 1), second.len);
}

test "a string with a sentinel carries it" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const empty = try auto.buildValue([:0]const u8, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectEqual(@as(u8, 0), empty[0]);
    const one = try auto.buildValue([:0]const u8, NoFactories, ctx, boundaryChoice(1));
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqual(@as(u8, 0), one[1]);
    const seeded = try auto.buildValue([:0]const u8, NoFactories, ctx, seededChoice(2));
    try std.testing.expectEqual(@as(u8, 0), seeded[seeded.len]);
}

test "a slice offers empty and one element and a slice the callee writes into also offers room" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    try std.testing.expectEqual(@as(usize, 0), (try auto.buildValue([]const u32, NoFactories, ctx, boundaryChoice(0))).len);
    try std.testing.expectEqual(@as(usize, 1), (try auto.buildValue([]const u32, NoFactories, ctx, boundaryChoice(1))).len);

    const read_only = try auto.listChoices([]const u32, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 2), countFrom(read_only, .boundary));
    const writable = try auto.listChoices([]u8, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 3), countFrom(writable, .boundary));
}

test "a slice the callee can write into is freshly allocated and can be written to" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const buffer = try auto.buildValue([]u8, NoFactories, ctx, boundaryChoice(2));
    try std.testing.expectEqual(@as(usize, 64), buffer.len);
    @memset(buffer, 'x');
    try std.testing.expectEqual(@as(u8, 'x'), buffer[63]);
    const other = try auto.buildValue([]u8, NoFactories, ctx, boundaryChoice(2));
    try std.testing.expect(buffer.ptr != other.ptr);
}

test "a one element slice holds the first boundary value of its element type" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const made = try auto.buildValue([]const bool, NoFactories, ctx, boundaryChoice(1));
    try std.testing.expectEqual(@as(usize, 1), made.len);
    try std.testing.expectEqual(false, made[0]);
}

test "an array steps its elements through the boundary values" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const made = try auto.buildValue([3]u8, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 255 }, &made);
}

test "a pointer to a value points at a freshly built one" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const made = try auto.buildValue(*u16, NoFactories, ctx, boundaryChoice(2));
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), made.*);
    made.* = 5;
    const constant = try auto.buildValue(*const u16, NoFactories, ctx, boundaryChoice(1));
    try std.testing.expectEqual(@as(u16, 1), constant.*);
}

test "a struct's fields step through their own boundary values together" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const Pair = struct { small: bool, wide: u8 };
    const first = try auto.buildValue(Pair, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqual(Pair{ .small = false, .wide = 0 }, first);
    const third = try auto.buildValue(Pair, NoFactories, ctx, boundaryChoice(2));
    try std.testing.expectEqual(Pair{ .small = false, .wide = 255 }, third);
    const choices = try auto.listChoices(Pair, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 3), countFrom(choices, .boundary));
}

test "a field with a default keeps it whatever the choice" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const List = struct {
        items: []const u8 = &.{},
        capacity: usize = 0,
        flag: bool,
    };
    for ([_]Choice{ boundaryChoice(0), boundaryChoice(1), seededChoice(0), seededChoice(3) }) |choice| {
        const made = try auto.buildValue(List, NoFactories, ctx, choice);
        try std.testing.expectEqual(@as(usize, 0), made.items.len);
        try std.testing.expectEqual(@as(usize, 0), made.capacity);
    }
}

test "a struct made only of defaults has no seeded choices" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const Settled = struct { capacity: usize = 0 };
    const choices = try auto.listChoices(Settled, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 1), choices.len);
}

test "a union offers every buildable variant and ignores the others" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const Mixed = union(enum) {
        flag: bool,
        number: u8,
        unusable: *anyopaque,
    };
    const choices = try auto.listChoices(Mixed, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 2 + 3), countFrom(choices, .boundary));
    try std.testing.expectEqual(Mixed{ .flag = false }, try auto.buildValue(Mixed, NoFactories, ctx, boundaryChoice(0)));
    try std.testing.expectEqual(Mixed{ .flag = true }, try auto.buildValue(Mixed, NoFactories, ctx, boundaryChoice(1)));
    try std.testing.expectEqual(Mixed{ .number = 0 }, try auto.buildValue(Mixed, NoFactories, ctx, boundaryChoice(2)));
    try std.testing.expectEqual(Mixed{ .number = 255 }, try auto.buildValue(Mixed, NoFactories, ctx, boundaryChoice(4)));
    var saw_flag = false;
    var saw_number = false;
    for (0..8) |index| {
        const made = try auto.buildValue(Mixed, NoFactories, ctx, seededChoice(@intCast(index)));
        switch (made) {
            .flag => saw_flag = true,
            .number => saw_number = true,
            .unusable => return error.UnbuildableVariantChosen,
        }
    }
    try std.testing.expect(saw_flag and saw_number);
}

test "a supplied type has one choice and gets what the run supplies" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const allocators = try auto.listChoices(std.mem.Allocator, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 1), allocators.len);
    const made = try auto.buildValue(std.mem.Allocator, NoFactories, ctx, allocators[0]);
    try std.testing.expectEqual(ctx.call_allocator.ptr, made.ptr);
    const writer = try auto.buildValue(*std.Io.Writer, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqual(ctx.writer, writer);
    const io = try auto.buildValue(std.Io, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqual(ctx.io.userdata, io.userdata);
    const random = try auto.buildValue(std.Random, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqual(ctx.random.ptr, random.ptr);
}

test "a supplied type inside a struct is supplied even when it has a default" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const Needs = struct { allocator: std.mem.Allocator = std.testing.failing_allocator, count: u8 };
    const made = try auto.buildValue(Needs, NoFactories, ctx, boundaryChoice(0));
    try std.testing.expectEqual(ctx.call_allocator.ptr, made.allocator.ptr);
}

test "an error set is given its first error and anyerror the supplied one" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const Narrow = error{ First, Second };
    var narrow: Narrow = undefined;
    try auto.buildValueInto(Narrow, NoFactories, ctx, boundaryChoice(0), &narrow);
    try std.testing.expectEqual(Narrow.First, narrow);
    var broad: anyerror = undefined;
    try auto.buildValueInto(anyerror, NoFactories, ctx, boundaryChoice(0), &broad);
    try std.testing.expectEqual(@as(anyerror, auto.supplied_error), broad);
    const Holder = struct { failure: Narrow, other: ?Narrow };
    const made = try auto.buildValue(Holder, NoFactories, ctx, boundaryChoice(1));
    try std.testing.expectEqual(Narrow.First, made.failure);
    try std.testing.expectEqual(@as(?Narrow, Narrow.First), made.other);
}

test "a void has one choice" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const choices = try auto.listChoices(void, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 1), choices.len);
}

test "an unbuildable type has no choices" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const choices = try auto.listChoices(*const fn () void, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 0), choices.len);
}

test "the boundary choices come first, then a few seeded ones and none repeat a value" {
    var h: Plain = undefined;
    h.start(7);
    defer h.finish();
    const ctx = h.context();
    const choices = try auto.listChoices(i32, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 5), countFrom(choices, .boundary));
    for (choices[0..5]) |choice| {
        try std.testing.expectEqual(auto.Source.boundary, choice.source);
    }
    try std.testing.expect(countFrom(choices, .seeded) <= 4);
    try std.testing.expectEqual(@as(usize, 0), countFrom(choices, .condition));
    for (choices, 0..) |choice, index| {
        const value = try auto.buildValue(i32, NoFactories, ctx, choice);
        for (choices[index + 1 ..]) |later| {
            try std.testing.expect(value != try auto.buildValue(i32, NoFactories, ctx, later));
        }
    }
}

test "the same seed builds the same values and a different seed builds different ones" {
    var first: Plain = undefined;
    first.start(12345);
    defer first.finish();
    var second: Plain = undefined;
    second.start(12345);
    defer second.finish();
    var third: Plain = undefined;
    third.start(54321);
    defer third.finish();

    var differed = false;
    for (0..4) |index| {
        const choice = seededChoice(@intCast(index));
        const one = try auto.buildValue(u64, NoFactories, first.context(), choice);
        const two = try auto.buildValue(u64, NoFactories, second.context(), choice);
        const other = try auto.buildValue(u64, NoFactories, third.context(), choice);
        try std.testing.expectEqual(one, two);
        if (one != other) {
            differed = true;
        }
    }
    try std.testing.expect(differed);

    const Record = struct { count: u32, name: []const u8, mode: enum { a, b, c }, ratio: f32 };
    for (0..4) |index| {
        const choice = seededChoice(@intCast(index));
        const one = try auto.buildValue(Record, NoFactories, first.context(), choice);
        const two = try auto.buildValue(Record, NoFactories, second.context(), choice);
        try std.testing.expectEqual(one.count, two.count);
        try std.testing.expectEqualStrings(one.name, two.name);
        try std.testing.expectEqual(one.mode, two.mode);
        try std.testing.expectEqual(one.ratio, two.ratio);
    }
}

test "the same choice built twice gives the same value" {
    var h: Plain = undefined;
    h.start(99);
    defer h.finish();
    const ctx = h.context();
    const one = try auto.buildValue(i64, NoFactories, ctx, seededChoice(2));
    const two = try auto.buildValue(i64, NoFactories, ctx, seededChoice(2));
    try std.testing.expectEqual(one, two);
}

test "two parameters of one type are not given the same seeded value" {
    var h: Plain = undefined;
    h.start(5);
    defer h.finish();
    var first = h.context();
    first.position = 0;
    var second = h.context();
    second.position = 1;
    var differed = false;
    for (0..4) |index| {
        const choice = seededChoice(@intCast(index));
        if (try auto.buildValue(u64, NoFactories, first, choice) != try auto.buildValue(u64, NoFactories, second, choice)) {
            differed = true;
        }
    }
    try std.testing.expect(differed);
}

test "seeded optionals, booleans, enums and slices are drawn from the seed" {
    var h: Plain = undefined;
    h.start(31);
    defer h.finish();
    const ctx = h.context();
    var saw_null = false;
    var saw_value = false;
    for (0..4) |index| {
        const made = try auto.buildValue(?u8, NoFactories, ctx, seededChoice(@intCast(index)));
        if (made == null) {
            saw_null = true;
        } else {
            saw_value = true;
        }
        const list = try auto.buildValue([]const u16, NoFactories, ctx, seededChoice(@intCast(index)));
        try std.testing.expect(list.len <= 8);
        _ = try auto.buildValue(bool, NoFactories, ctx, seededChoice(@intCast(index)));
        _ = try auto.buildValue([3]u8, NoFactories, ctx, seededChoice(@intCast(index)));
        _ = try auto.buildValue(*f32, NoFactories, ctx, seededChoice(@intCast(index)));
    }
    try std.testing.expect(saw_null and saw_value);
}

test "choices from conditions come after the boundary and seeded ones" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    h.conditions = &.{comparison(.{ .int = 1000 })};
    const ctx = h.context();
    const choices = try auto.listChoices(u32, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 3), countFrom(choices, .condition));
    var built: [3]u32 = undefined;
    var found: usize = 0;
    for (choices) |choice| {
        if (choice.source == .condition) {
            built[found] = try auto.buildValue(u32, NoFactories, ctx, choice);
            found += 1;
        }
    }
    try std.testing.expectEqualSlices(u32, &.{ 1000, 999, 1001 }, &built);
}

test "a condition value that is already a boundary value is not offered twice" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    h.conditions = &.{comparison(.{ .int = 0 })};
    const choices = try auto.listChoices(u8, NoFactories, h.context());
    // The literal zero and the one above it are boundary values already and the one below zero cannot be held.
    try std.testing.expectEqual(@as(usize, 0), countFrom(choices, .condition));
}

test "without conditions there are no condition choices" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const choices = try auto.listChoices(u32, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 0), countFrom(choices, .condition));
}

test "string, enum and optional conditions become choices" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const Mode = enum { fast, slow, off };
    h.conditions = &.{
        .{ .line = 1, .kind = .string_equals, .literal = .{ .string = "stop" }, .subject = "name" },
        .{ .line = 2, .kind = .switch_prong, .literal = .{ .enum_tag = "off" } },
        .{ .line = 3, .kind = .optional_check, .subject = "maybe" },
    };
    const ctx = h.context();

    const strings = try auto.listChoices([]const u8, NoFactories, ctx);
    var found_stop = false;
    for (strings) |choice| {
        if (choice.source == .condition) {
            if (std.mem.eql(u8, "stop", try auto.buildValue([]const u8, NoFactories, ctx, choice))) {
                found_stop = true;
            }
        }
    }
    try std.testing.expect(found_stop);

    const modes = try auto.listChoices(Mode, NoFactories, ctx);
    // `off` is a boundary value as well, so the condition adds nothing new.
    try std.testing.expectEqual(@as(usize, 0), countFrom(modes, .condition));

    const optionals = try auto.listChoices(?u8, NoFactories, ctx);
    try std.testing.expectEqual(@as(usize, 0), countFrom(optionals, .condition));
}

test "a struct takes the conditions for the fields they apply to" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    h.conditions = &.{ comparison(.{ .int = 500 }), .{ .line = 2, .kind = .string_equals, .literal = .{ .string = "go" }, .subject = "name" } };
    const ctx = h.context();
    const Request = struct { size: u32, name: []const u8, retry: bool };
    const choices = try auto.listChoices(Request, NoFactories, ctx);
    var saw_size = false;
    var saw_name = false;
    for (choices) |choice| {
        if (choice.source != .condition) {
            continue;
        }
        const made = try auto.buildValue(Request, NoFactories, ctx, choice);
        if (made.size == 500 or made.size == 499 or made.size == 501) {
            saw_size = true;
        }
        if (std.mem.eql(u8, made.name, "go")) {
            saw_name = true;
        }
    }
    try std.testing.expect(saw_size and saw_name);
}

test "a condition choice for a type the conditions say nothing about builds its first boundary value" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    const made = try auto.buildValue(u8, NoFactories, h.context(), conditionChoice(3));
    try std.testing.expectEqual(@as(u8, 0), made);
    const list = try auto.buildValue([]const u32, NoFactories, h.context(), conditionChoice(1));
    try std.testing.expectEqual(@as(usize, 1), list.len);
}

test "a value factory type offers one choice per factory in declaration order and the first is the baseline" {
    var h: Harness(WithReader) = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const choices = try auto.listChoices(SourceSim.Reader, WithReader, ctx);
    try std.testing.expectEqual(@as(usize, 2), choices.len);
    for (choices, 0..) |choice, index| {
        try std.testing.expectEqual(auto.Source.factory, choice.source);
        try std.testing.expectEqual(@as(u32, @intCast(index)), choice.index);
    }
    const working = try auto.buildValue(SourceSim.Reader, WithReader, ctx, choices[0]);
    try std.testing.expectEqual(@as(u8, 1), working.read());
    const broken = try auto.buildValue(SourceSim.Reader, WithReader, ctx, choices[1]);
    try std.testing.expectEqual(@as(u8, 0), broken.read());
}

test "a value factory for a built-in type adds a choice after the built-in ones and does not replace them" {
    var h: Harness(WithReader) = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const choices = try auto.listChoices(u32, WithReader, ctx);
    try std.testing.expectEqual(auto.Source.boundary, choices[0].source);
    const last = choices[choices.len - 1];
    try std.testing.expectEqual(auto.Source.factory, last.source);
    try std.testing.expectEqual(@as(u32, 4242), try auto.buildValue(u32, WithReader, ctx, last));
}

test "a factory choice for a type with no factory is an error" {
    var h: Plain = undefined;
    h.start(1);
    defer h.finish();
    try std.testing.expectError(error.NoValueFactory, auto.buildValue(u8, NoFactories, h.context(), .{ .source = .factory, .index = 0 }));
}

test "a factory index past the last factory is an error" {
    var h: Harness(WithReader) = undefined;
    h.start(1);
    defer h.finish();
    try std.testing.expectError(error.NoSuchValueFactory, auto.buildValue(SourceSim.Reader, WithReader, h.context(), .{ .source = .factory, .index = 5 }));
}

test "a type holding one built by a factory picks the factory from the choice's index" {
    var h: Harness(WithReader) = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const Holder = struct { reader: SourceSim.Reader, limit: u8 };
    const choices = try auto.listChoices(Holder, WithReader, ctx);
    try std.testing.expectEqual(@as(usize, 3), countFrom(choices, .boundary));
    const first = try auto.buildValue(Holder, WithReader, ctx, boundaryChoice(0));
    try std.testing.expectEqual(@as(u8, 1), first.reader.read());
    const second = try auto.buildValue(Holder, WithReader, ctx, boundaryChoice(1));
    try std.testing.expectEqual(@as(u8, 0), second.reader.read());
}

// A sim file with a struct factory that keeps state, whose factory takes a parameter.
const CounterSim = struct {
    pub const Ticket = struct { number: u32 };

    pub const Dispenser = struct {
        issued: u32 = 0,

        pub fn next(self: *Dispenser, step: u32) Ticket {
            self.issued += 1 + step;
            return .{ .number = self.issued };
        }
    };
};
const WithCounter = locator.Locator(CounterSim);

test "a struct factory keeps its state across the values built in one series and reset starts again" {
    var h: Harness(WithCounter) = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const factory: Choice = .{ .source = .factory, .index = 0 };
    // The factory's own parameter is built from its first boundary value, zero.
    try std.testing.expectEqual(@as(u32, 1), (try auto.buildValue(CounterSim.Ticket, WithCounter, ctx, factory)).number);
    try std.testing.expectEqual(@as(u32, 2), (try auto.buildValue(CounterSim.Ticket, WithCounter, ctx, factory)).number);
    try std.testing.expectEqual(@as(u32, 3), (try auto.buildValue(CounterSim.Ticket, WithCounter, ctx, factory)).number);
    h.factories.reset();
    try std.testing.expectEqual(@as(u32, 1), (try auto.buildValue(CounterSim.Ticket, WithCounter, ctx, factory)).number);
}

fn pairSum(first: u8, second: bool) u32 {
    return @as(u32, first) + @intFromBool(second);
}

fn takesBuffer(buffer: []u8, text: []const u8) usize {
    return buffer.len + text.len;
}

test "the call specifications start with the baseline and are the same every time" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const ctx = h.context();
    const first = try auto.listCallSpecs(@TypeOf(pairSum), NoFactories, ctx);
    const second = try auto.listCallSpecs(@TypeOf(pairSum), NoFactories, ctx);
    try std.testing.expect(first.len > 1);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |one, other| {
        try std.testing.expectEqual(one.len, other.len);
        for (one, other) |a, b| {
            try std.testing.expectEqual(a, b);
        }
    }
    try std.testing.expectEqual(boundaryChoice(0), first[0][0]);
    try std.testing.expectEqual(boundaryChoice(0), first[0][1]);
    // Every spec has one choice per parameter.
    for (first) |spec| {
        try std.testing.expectEqual(@as(usize, 2), spec.len);
    }
}

test "every other choice of a parameter is tried with the others at their baseline" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const ctx = h.context();
    const lists = try auto.listParameterChoices(@TypeOf(pairSum), NoFactories, ctx);
    const specs = try auto.listCallSpecs(@TypeOf(pairSum), NoFactories, ctx);
    var expected_singles: usize = 0;
    for (lists) |list| {
        expected_singles += list.len - 1;
    }
    var singles: usize = 0;
    for (specs[1..]) |spec| {
        const first_baseline = spec[0].source == lists[0][0].source and spec[0].index == lists[0][0].index;
        const second_baseline = spec[1].source == lists[1][0].source and spec[1].index == lists[1][0].index;
        if (first_baseline or second_baseline) {
            singles += 1;
        }
    }
    try std.testing.expectEqual(expected_singles, singles);
    try std.testing.expectEqual(@as(usize, 2), lists.len);
    try std.testing.expect(lists[0].len > 3 and lists[1].len == 2);
}

test "the arguments built from a specification are the values it names" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const ctx = h.context();
    const args = try auto.buildArguments(@TypeOf(pairSum), NoFactories, ctx, &.{ boundaryChoice(2), boundaryChoice(1) });
    try std.testing.expectEqual(@as(u8, 255), args[0]);
    try std.testing.expectEqual(true, args[1]);
}

test "a specification of the wrong length is refused" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    try std.testing.expectError(error.WrongSpecLength, auto.buildArguments(@TypeOf(pairSum), NoFactories, h.context(), &.{boundaryChoice(0)}));
}

test "a function with no parameter that can be built has no specifications" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const Function = fn (callback: *const fn () void) void;
    const specs = try auto.listCallSpecs(Function, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 0), specs.len);
}

test "a function with no parameters has one empty specification" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const specs = try auto.listCallSpecs(@TypeOf(noop), NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    try std.testing.expectEqual(@as(usize, 0), specs[0].len);
}

test "supplied parameters have one choice and take no part in the changes" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const Function = fn (allocator: std.mem.Allocator, count: bool) void;
    const specs = try auto.listCallSpecs(Function, NoFactories, h.context());
    try std.testing.expectEqual(@as(usize, 2), specs.len);
    try std.testing.expectEqual(boundaryChoice(0), specs[0][0]);
    try std.testing.expectEqual(boundaryChoice(0), specs[1][0]);
}

test "a slice parameter the function writes into is given room by one of the specifications" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    const ctx = h.context();
    const specs = try auto.listCallSpecs(@TypeOf(takesBuffer), NoFactories, ctx);
    var saw_room = false;
    for (specs) |spec| {
        const args = try auto.buildArguments(@TypeOf(takesBuffer), NoFactories, ctx, spec);
        if (args[0].len == 64) {
            saw_room = true;
        }
    }
    try std.testing.expect(saw_room);
}

var calls_seen: u32 = 0;
var last_total: u32 = 0;

fn recordCall(first: u8, second: bool) error{Refused}!void {
    calls_seen += 1;
    last_total = pairSum(first, second);
    if (first == 255) {
        return error.Refused;
    }
}

test "callOnce calls the function with the specification's arguments and ignores its error" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    calls_seen = 0;
    try auto.callOnce(recordCall, NoFactories, h.context(), &.{ boundaryChoice(2), boundaryChoice(1) });
    try std.testing.expectEqual(@as(u32, 1), calls_seen);
    try std.testing.expectEqual(@as(u32, 256), last_total);
    try auto.callOnce(recordCall, NoFactories, h.context(), &.{ boundaryChoice(1), boundaryChoice(0) });
    try std.testing.expectEqual(@as(u32, 2), calls_seen);
}

test "callOnce passes on an error from building the arguments" {
    var h: Plain = undefined;
    h.start(3);
    defer h.finish();
    try std.testing.expectError(error.WrongSpecLength, auto.callOnce(recordCall, NoFactories, h.context(), &.{}));
}

fn generic(value: anytype) void {
    _ = value;
}

fn needsCallback(callback: *const fn () void) void {
    _ = callback;
}

test "canExercise accepts a function whose parameters can all be built and refuses the rest" {
    try std.testing.expect(comptime auto.canExercise(@TypeOf(pairSum), NoFactories));
    try std.testing.expect(comptime auto.canExercise(@TypeOf(noop), NoFactories));
    try std.testing.expect(!(comptime auto.canExercise(@TypeOf(needsCallback), NoFactories)));
    try std.testing.expect(!(comptime auto.canExercise(@TypeOf(generic), NoFactories)));
    try std.testing.expect(!(comptime auto.canExercise(u32, NoFactories)));
}

test "canExercise accepts a function whose parameter a value factory builds" {
    const Function = fn (reader: SourceSim.Reader) void;
    try std.testing.expect(comptime auto.canExercise(Function, WithReader));
    try std.testing.expect(!(comptime auto.canExercise(Function, NoFactories)));
}

test "firstUnbuildableParameter names the type to write a value factory for" {
    try std.testing.expect(comptime auto.firstUnbuildableParameter(@TypeOf(pairSum), NoFactories) == null);
    try std.testing.expect(comptime auto.firstUnbuildableParameter(@TypeOf(needsCallback), NoFactories).? == *const fn () void);
    try std.testing.expect(comptime auto.firstUnbuildableParameter(@TypeOf(generic), NoFactories) == null);
    const Function = fn (count: u8, reader: SourceSim.Reader, more: *anyopaque) void;
    try std.testing.expect(comptime auto.firstUnbuildableParameter(Function, NoFactories).? == SourceSim.Reader);
    try std.testing.expect(comptime auto.firstUnbuildableParameter(Function, WithReader).? == *anyopaque);
}

// A sim file whose value factories return errors, for a function that words each error.
const ErrorSim = struct {
    pub fn missingFile() anyerror {
        return error.FileNotFound;
    }

    pub fn deniedAccess() anyerror {
        return error.AccessDenied;
    }
};

const WithErrors = locator.Locator(ErrorSim);

test "anyerror is offered the supplied error first and then every value factory that returns one" {
    var h: Harness(WithErrors) = undefined;
    h.start(1);
    defer h.finish();
    const ctx = h.context();
    const choices = try auto.listChoices(anyerror, WithErrors, ctx);
    try std.testing.expectEqual(auto.Source.boundary, choices[0].source);
    try std.testing.expectEqual(@as(usize, 3), choices.len);

    var built: anyerror = undefined;
    try auto.buildValueInto(anyerror, WithErrors, ctx, choices[0], &built);
    try std.testing.expectEqual(@as(anyerror, auto.supplied_error), built);
    try auto.buildValueInto(anyerror, WithErrors, ctx, choices[1], &built);
    try std.testing.expectEqual(@as(anyerror, error.FileNotFound), built);
    try auto.buildValueInto(anyerror, WithErrors, ctx, choices[2], &built);
    try std.testing.expectEqual(@as(anyerror, error.AccessDenied), built);
}
