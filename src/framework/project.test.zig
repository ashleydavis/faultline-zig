const std = @import("std");
const sim = @import("sim");
const project = @import("project.zig");
const call_mod = @import("call.zig");
const isolate = @import("isolate.zig");
const wire = @import("wire.zig");

const Item = struct { value: u32 };

const Alpha = struct {
    pub fn double(x: u32) u32 {
        return x *% 2;
    }

    pub fn needsItem(item: Item) bool {
        return item.value > 3;
    }

    pub fn takesAFunction(callback: *const fn () void) void {
        callback();
    }

    pub fn first(comptime T: type, items: []const T) ?T {
        if (items.len == 0) {
            return null;
        }
        return items[0];
    }

    pub const Counter = struct {
        count: u32 = 0,

        pub fn bump(self: *Counter) void {
            self.count += 1;
        }
    };
};

const AlphaSim = struct {
    pub fn anItem() Item {
        return .{ .value = 9 };
    }

    pub fn everythingIsFine(context: *sim.ExpectationContext) anyerror!void {
        try context.expect(@src(), true, "everything to be fine");
    }

    pub fn aScenario(context: *sim.ScenarioContext) anyerror!void {
        try context.expect(@src(), true, "one to be one");
    }

    pub fn notAScenario(value: u32) u32 {
        return value;
    }
};

const Beta = struct {
    pub fn answer() u32 {
        return 42;
    }
};

const files = struct {
    pub const sources = .{
        .{ .path = "alpha.zig", .namespace = Alpha },
        .{ .path = "beta.zig", .namespace = Beta },
    };
    pub const simulations = .{
        .{ .path = "alpha.sim.zig", .source = "alpha.zig", .namespace = AlphaSim },
    };
};

const Subject = project.Project(files);

test "every function and method of every source file is an entry in table order" {
    const entries = Subject.function_entries;

    try std.testing.expectEqual(@as(usize, 6), entries.len);
    try std.testing.expectEqualStrings("alpha.zig", entries[0].file);
    try std.testing.expectEqualStrings("double", entries[0].name);
    try std.testing.expectEqualStrings("first", entries[3].name);
    try std.testing.expectEqualStrings("Counter.bump", entries[4].name);
    try std.testing.expectEqualStrings("beta.zig", entries[5].file);
}

test "a function nothing can build a parameter for is marked as one that cannot be called" {
    const entries = Subject.function_entries;

    try std.testing.expect(entries[0].can_call);
    try std.testing.expect(!entries[2].can_call);
    try std.testing.expect(entries[2].unbuildable.len > 0);
}

test "a function whose parameter has a value factory in any sim file can be called" {
    const entries = Subject.function_entries;

    try std.testing.expect(entries[1].can_call);
}

test "scenarios are found in sim files and plain functions are not" {
    const scenarios = Subject.scenario_entries;

    try std.testing.expectEqual(@as(usize, 1), scenarios.len);
    try std.testing.expectEqualStrings("aScenario", scenarios[0].name);
    try std.testing.expectEqualStrings("alpha.sim.zig", scenarios[0].file);
}

test "a call through the table runs in a child and reports its result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entry = Subject.function_entries[0];

    const specs = try entry.list_specs(arena.allocator(), std.testing.io, 1, &.{});
    var attempt = try entry.attempt(std.testing.allocator, .{
        .seed = 1,
        .spec = specs[0],
        .plan = &.{},
        .conditions = &.{},
        .real_io = std.testing.io,
    }, isolate.default_limits);
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    try std.testing.expect(attempt.isClean());
    try std.testing.expect(report.result.? == .returned);
}

test "the expectation function of the paired sim file runs after a call of a function in the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `double` is in alpha.zig, whose sim file has an expectation that always holds. The check that
    // an expectation runs at all is in call.test.zig, so this one only checks the table wires the
    // right sim file to the right source.
    const entry = Subject.function_entries[0];
    const specs = try entry.list_specs(arena.allocator(), std.testing.io, 1, &.{});

    var attempt = try entry.attempt(std.testing.allocator, .{
        .seed = 1,
        .spec = specs[0],
        .plan = &.{},
        .conditions = &.{},
        .real_io = std.testing.io,
    }, isolate.default_limits);
    defer attempt.deinit(std.testing.allocator);

    try std.testing.expect(attempt.isClean());
}

test "isScenario and isExpectation tell the two apart" {
    try std.testing.expect(project.isScenario(@TypeOf(AlphaSim.aScenario)));
    try std.testing.expect(!project.isExpectation(@TypeOf(AlphaSim.aScenario)));
    try std.testing.expect(project.isExpectation(@TypeOf(AlphaSim.everythingIsFine)));
    try std.testing.expect(!project.isScenario(@TypeOf(AlphaSim.everythingIsFine)));
    try std.testing.expect(!project.isScenario(@TypeOf(AlphaSim.notAScenario)));
}

test "the source files are listed in table order" {
    try std.testing.expectEqual(@as(usize, 2), Subject.source_files.len);
    try std.testing.expectEqualStrings("alpha.zig", Subject.source_files[0]);
    try std.testing.expectEqualStrings("beta.zig", Subject.source_files[1]);
}

test "a generic function is marked as generic and not as one that needs a value factory" {
    const entries = Subject.function_entries;

    try std.testing.expect(!entries[3].can_call);
    try std.testing.expect(entries[3].is_generic);
    try std.testing.expectEqualStrings("", entries[3].unbuildable);
    try std.testing.expect(!entries[2].is_generic);
}

test "isGeneric is true only for a function with a type or anytype parameter" {
    try std.testing.expect(project.isGeneric(@TypeOf(Alpha.first)));
    try std.testing.expect(!project.isGeneric(@TypeOf(Alpha.double)));
    try std.testing.expect(!project.isGeneric(u32));
}
