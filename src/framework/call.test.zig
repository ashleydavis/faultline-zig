const std = @import("std");
const sim = @import("sim");
const call = @import("call.zig");
const call_specs = @import("call_specs.zig");
const injector = @import("injector.zig");
const failures = @import("failures.zig");
const isolate = @import("isolate.zig");
const locator = @import("locator.zig");
const wire = @import("wire.zig");
const point = @import("point.zig");

const Item = struct { value: u32 };

// What the fixture functions below are written against.
const Fixture = struct {
    pub fn classify(x: i32) []const u8 {
        if (x > 10) {
            return "big";
        }
        return "small";
    }

    pub fn failsOnZero(x: u8) !void {
        if (x == 0) {
            return error.WasZero;
        }
    }

    pub fn allocates(allocator: std.mem.Allocator) !void {
        const memory = try allocator.alloc(u8, 4);
        allocator.free(memory);
    }

    pub fn takesAFunction(callback: *const fn () void) void {
        callback();
    }

    pub fn crashesOnTwo(item: Item) void {
        if (item.value == 2) {
            @panic("the item was two");
        }
    }
};

// The factories the fixture's sim file would hold.
const FixtureSim = struct {
    pub fn goodItem() Item {
        return .{ .value = 1 };
    }

    pub fn crashingItem() Item {
        return .{ .value = 2 };
    }

    pub fn alwaysFalse(context: *sim.ExpectationContext) anyerror!void {
        try context.expect(@src(), false, "the world to be fine");
    }

    pub fn alwaysTrue(context: *sim.ExpectationContext) anyerror!void {
        try context.expect(@src(), true, "the world to be fine");
    }

    pub fn failingScenario(context: *sim.ScenarioContext) anyerror!void {
        try context.expect(@src(), 1 == 2, "one to be two");
    }

    pub fn passingScenario(context: *sim.ScenarioContext) anyerror!void {
        try context.expect(@src(), 1 == 1, "one to be one");
    }
};

const Factories = locator.Locator(FixtureSim);
const NoFactories = locator.Locator(struct {});

const no_expectations = .{};
const true_expectations = .{.{ .name = "alwaysTrue", .call = FixtureSim.alwaysTrue }};
const false_expectations = .{.{ .name = "alwaysFalse", .call = FixtureSim.alwaysFalse }};

fn runChild(child: anytype) !isolate.Attempt {
    return isolate.attempt(std.testing.allocator, child, isolate.default_limits);
}

fn requestFor(spec: call_specs.Spec, plan: []const injector.Injection) call.Request {
    return .{
        .seed = 5,
        .spec = spec,
        .plan = plan,
        .conditions = &.{},
        .real_io = std.testing.io,
    };
}

test "a function that can be called is known to be callable and one that cannot is named" {
    const Callable = call.Call(NoFactories, Fixture.classify, no_expectations);
    const NeedsAFunction = call.Call(NoFactories, Fixture.takesAFunction, no_expectations);

    try std.testing.expect(Callable.can_call);
    try std.testing.expectEqualStrings("", Callable.unbuildable);
    try std.testing.expect(!NeedsAFunction.can_call);
    try std.testing.expect(NeedsAFunction.unbuildable.len > 0);
}

test "listing the specifications for a function gives a baseline first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Classify = call.Call(NoFactories, Fixture.classify, no_expectations);

    const specs = try Classify.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    try std.testing.expect(specs.len > 1);
    try std.testing.expectEqual(@as(usize, 1), specs[0].len);
}

test "a call that returns is reported as returned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Classify = call.Call(NoFactories, Fixture.classify, no_expectations);
    const specs = try Classify.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    var attempt = try runChild(Classify.Child{ .request = requestFor(specs[0], &.{}) });
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    try std.testing.expect(attempt.isClean());
    try std.testing.expect(report.result.? == .returned);
}

test "a call that returns an error is reported with the error name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Fails = call.Call(NoFactories, Fixture.failsOnZero, no_expectations);
    const specs = try Fails.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    // The baseline of an integer is zero.
    var attempt = try runChild(Fails.Child{ .request = requestFor(specs[0], &.{}) });
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    try std.testing.expectEqualStrings("WasZero", report.result.?.errored);
}

test "a call records the places it reached and a planned failure changes the result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Allocates = call.Call(NoFactories, Fixture.allocates, no_expectations);
    const specs = try Allocates.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    var clean = try runChild(Allocates.Child{ .request = requestFor(specs[0], &.{}) });
    defer clean.deinit(std.testing.allocator);
    var clean_report = try wire.read(std.testing.allocator, clean.output);
    defer clean_report.deinit();
    try std.testing.expect(clean_report.result.? == .returned);
    try std.testing.expect(clean_report.places.len >= 1);
    try std.testing.expectEqual(point.Effect.allocator, clean_report.places[0].point.effect);

    var kind: u8 = 0;
    for (failures.kindsOf(.allocator), 0..) |row, index| {
        if (std.mem.eql(u8, row.id, "allocation_fails")) {
            kind = @intCast(index);
        }
    }
    const plan = [_]injector.Injection{.{ .point = .{ .effect = .allocator, .occurrence = 0 }, .kind = kind }};
    var failing = try runChild(Allocates.Child{ .request = requestFor(specs[0], &plan) });
    defer failing.deinit(std.testing.allocator);
    var failing_report = try wire.read(std.testing.allocator, failing.output);
    defer failing_report.deinit();

    try std.testing.expectEqualStrings("OutOfMemory", failing_report.result.?.errored);
}

test "a call that crashes ends its child with a signal and says nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Crashes = call.Call(Factories, Fixture.crashesOnTwo, no_expectations);
    const specs = try Crashes.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    // The factories are good first and crashing second.
    var crashed = false;
    for (specs) |spec| {
        var attempt = try runChild(Crashes.Child{ .request = requestFor(spec, &.{}) });
        defer attempt.deinit(std.testing.allocator);
        if (attempt.ending == .signaled) {
            crashed = true;
            try std.testing.expect(std.mem.indexOf(u8, attempt.complaint, "the item was two") != null);
        }
    }
    try std.testing.expect(crashed);
}

test "an expectation function that is false replaces the outcome of the call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Classify = call.Call(NoFactories, Fixture.classify, false_expectations);
    const specs = try Classify.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    var attempt = try runChild(Classify.Child{ .request = requestFor(specs[0], &.{}) });
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    const failure = report.result.?.expectation_failed;
    try std.testing.expectEqualStrings("alwaysFalse", failure.function);
    try std.testing.expectEqualStrings("the world to be fine", failure.text);
}

test "an expectation function that is true leaves the outcome alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Classify = call.Call(NoFactories, Fixture.classify, true_expectations);
    const specs = try Classify.listSpecs(arena.allocator(), std.testing.io, 7, &.{});

    var attempt = try runChild(Classify.Child{ .request = requestFor(specs[0], &.{}) });
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    try std.testing.expect(report.result.? == .returned);
}

test "a scenario with a false expectation is reported with its own name" {
    const Failing = call.Scenario("failingScenario", FixtureSim.failingScenario, no_expectations);

    var attempt = try runChild(Failing.Child{ .real_io = std.testing.io, .seed = 1 });
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    const failure = report.result.?.expectation_failed;
    try std.testing.expectEqualStrings("failingScenario", failure.function);
    try std.testing.expectEqualStrings("one to be two", failure.text);
}

test "a scenario that holds is reported as returned and its sim file's expectations run after it" {
    const Passing = call.Scenario("passingScenario", FixtureSim.passingScenario, false_expectations);

    var attempt = try runChild(Passing.Child{ .real_io = std.testing.io, .seed = 1 });
    defer attempt.deinit(std.testing.allocator);
    var report = try wire.read(std.testing.allocator, attempt.output);
    defer report.deinit();

    try std.testing.expectEqualStrings("alwaysFalse", report.result.?.expectation_failed.function);
}

test "writeValue writes a string in quotes, Faultline's own values by what they are and the rest as Zig does" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try call.writeValue(&out.writer, @as([]const u8, "a\"b"));
    try out.writer.writeByte('|');
    try call.writeValue(&out.writer, std.testing.allocator);
    try out.writer.writeByte('|');
    try call.writeValue(&out.writer, @as(usize, 7));
    try out.writer.writeByte('|');
    try call.writeValue(&out.writer, true);

    try std.testing.expectEqualStrings("\"a\\\"b\"|the allocator Faultline supplies|7|true", out.written());
}

test "writeValue writes the strings inside a struct and an optional as strings" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const Package = struct { name: []const u8, size: u8, note: ?[]const u8 };

    try call.writeValue(&out.writer, Package{ .name = "a", .size = 3, .note = null });
    try out.writer.writeByte('|');
    try call.writeValue(&out.writer, @as(?[]const u8, "b"));

    try std.testing.expectEqualStrings(".{ .name = \"a\", .size = 3, .note = null }|\"b\"", out.written());
}
