// Tests for the finders: value factories, scenarios and expectation functions in a sim file.

const std = @import("std");
const finders = @import("finders.zig");

// Reads one snippet as the sim file `src/thing.sim.zig`.
fn find(source: [:0]const u8) !finders.Findings {
    return finders.findIn(std.testing.allocator, source, "src/thing.sim.zig");
}

test "a public function returning a type of the project is a value factory" {
    const findings = try find(
        \\const sim = @import("sim");
        \\const Item = @import("thing.zig").Item;
        \\
        \\pub fn working() Item {
        \\    return .{};
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), findings.factories.len);
    try std.testing.expectEqualStrings("working", findings.factories[0].name);
    try std.testing.expectEqualStrings("Item", findings.factories[0].return_type);
    try std.testing.expectEqualStrings("Item", findings.factories[0].value_type);
    try std.testing.expect(findings.factories[0].struct_name == null);
    try std.testing.expectEqual(@as(u32, 4), findings.factories[0].line);
    try std.testing.expectEqual(@as(usize, 0), findings.scenarios.len);
    try std.testing.expectEqual(@as(usize, 0), findings.expectations.len);
}

test "several factories for one type are all found, in the order declared" {
    const findings = try find(
        \\pub fn working() Item {
        \\    return .{};
        \\}
        \\pub fn failsWithNotFound() Item {
        \\    return .{};
        \\}
        \\pub fn failsWithExit() Item {
        \\    return .{};
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), findings.factories.len);
    try std.testing.expectEqualStrings("working", findings.factories[0].name);
    try std.testing.expectEqualStrings("failsWithNotFound", findings.factories[1].name);
    try std.testing.expectEqualStrings("failsWithExit", findings.factories[2].name);
}

test "the return type text keeps an error set or a question mark and the value type drops it" {
    const findings = try find(
        \\pub fn inferred() !Item {
        \\    return .{};
        \\}
        \\pub fn named() error{Broken}!Item {
        \\    return .{};
        \\}
        \\pub fn optional() ?Item {
        \\    return null;
        \\}
        \\pub fn through() models.Item {
        \\    return .{};
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), findings.factories.len);
    try std.testing.expectEqualStrings("!Item", findings.factories[0].return_type);
    try std.testing.expectEqualStrings("Item", findings.factories[0].value_type);
    try std.testing.expectEqualStrings("error{Broken}!Item", findings.factories[1].return_type);
    try std.testing.expectEqualStrings("Item", findings.factories[1].value_type);
    try std.testing.expectEqualStrings("?Item", findings.factories[2].return_type);
    try std.testing.expectEqualStrings("Item", findings.factories[2].value_type);
    try std.testing.expectEqualStrings("models.Item", findings.factories[3].return_type);
    try std.testing.expectEqualStrings("models.Item", findings.factories[3].value_type);
}

test "a function returning a type of the language or of std is not a value factory" {
    const findings = try find(
        \\pub fn a() void {}
        \\pub fn b() bool {
        \\    return true;
        \\}
        \\pub fn c() u32 {
        \\    return 1;
        \\}
        \\pub fn d() i64 {
        \\    return 1;
        \\}
        \\pub fn e() usize {
        \\    return 1;
        \\}
        \\pub fn f() f64 {
        \\    return 1;
        \\}
        \\pub fn g() anyerror!void {}
        \\pub fn h() []const u8 {
        \\    return "";
        \\}
        \\pub fn i() std.ArrayList(u8) {
        \\    return .empty;
        \\}
        \\pub fn j() std.mem.Allocator {
        \\    return undefined;
        \\}
        \\pub fn k() type {
        \\    return u8;
        \\}
        \\pub fn l() *Item {
        \\    return undefined;
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
}

test "a private function is not a value factory" {
    const findings = try find(
        \\fn hidden() Item {
        \\    return .{};
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
}

test "a top-level value factory may take parameters and their type text is recorded" {
    const findings = try find(
        \\pub fn none() Item {
        \\    return .{};
        \\}
        \\pub fn needs(value: u32, name: []const u8, other: ?models.Thing, any: anytype) Item {
        \\    _ = value;
        \\    _ = name;
        \\    _ = other;
        \\    _ = any;
        \\    return .{};
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), findings.factories.len);
    try std.testing.expectEqual(@as(usize, 0), findings.factories[0].parameters.len);
    const parameters = findings.factories[1].parameters;
    try std.testing.expectEqual(@as(usize, 4), parameters.len);
    try std.testing.expectEqualStrings("u32", parameters[0]);
    try std.testing.expectEqualStrings("[]const u8", parameters[1]);
    try std.testing.expectEqualStrings("?models.Thing", parameters[2]);
    try std.testing.expectEqualStrings("anytype", parameters[3]);
}

test "a struct factory may take self by pointer or by value and further parameters, which are recorded without self" {
    const findings = try find(
        \\pub const Runner = struct {
        \\    pub fn byPointer(self: *Runner, count: u32) Item {
        \\        _ = self;
        \\        _ = count;
        \\        return .{};
        \\    }
        \\    pub fn byValue(self: Runner) Item {
        \\        _ = self;
        \\        return .{};
        \\    }
        \\    pub fn byConst(self: *const Self, a: bool, b: u8) Item {
        \\        _ = self;
        \\        _ = a;
        \\        _ = b;
        \\        return .{};
        \\    }
        \\};
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), findings.factories.len);
    try std.testing.expectEqual(@as(usize, 1), findings.factories[0].parameters.len);
    try std.testing.expectEqualStrings("u32", findings.factories[0].parameters[0]);
    try std.testing.expectEqual(@as(usize, 0), findings.factories[1].parameters.len);
    try std.testing.expectEqual(@as(usize, 2), findings.factories[2].parameters.len);
    try std.testing.expectEqualStrings("bool", findings.factories[2].parameters[0]);
    try std.testing.expectEqualStrings("u8", findings.factories[2].parameters[1]);
}

test "a public method on a public struct taking self and returning a value is a struct factory" {
    const findings = try find(
        \\pub const Runner = struct {
        \\    calls: u32 = 0,
        \\
        \\    pub fn next(self: *Runner) Item {
        \\        self.calls += 1;
        \\        return .{};
        \\    }
        \\
        \\    pub fn fails(self: *Self) !Item {
        \\        return error.Broken;
        \\    }
        \\};
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), findings.factories.len);
    try std.testing.expectEqualStrings("next", findings.factories[0].name);
    try std.testing.expectEqualStrings("Runner", findings.factories[0].struct_name.?);
    try std.testing.expectEqualStrings("Item", findings.factories[0].return_type);
    try std.testing.expectEqual(@as(u32, 4), findings.factories[0].line);
    try std.testing.expectEqualStrings("fails", findings.factories[1].name);
    try std.testing.expectEqualStrings("Runner", findings.factories[1].struct_name.?);
    try std.testing.expectEqualStrings("!Item", findings.factories[1].return_type);
}

test "a struct method is not a factory when private, when it returns a language type, when it has no self or when self is another type" {
    const findings = try find(
        \\pub const Runner = struct {
        \\    fn hidden(self: *Runner) Item {
        \\        _ = self;
        \\        return .{};
        \\    }
        \\    pub fn count(self: *Runner) u32 {
        \\        _ = self;
        \\        return 1;
        \\    }
        \\    pub fn make() Item {
        \\        return .{};
        \\    }
        \\    pub fn other(self: *Different) Item {
        \\        _ = self;
        \\        return .{};
        \\    }
        \\};
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
}

test "methods of a private struct and of something that is not a struct are not factories" {
    const findings = try find(
        \\const Hidden = struct {
        \\    pub fn next(self: *Hidden) Item {
        \\        _ = self;
        \\        return .{};
        \\    }
        \\};
        \\pub const Choice = enum {
        \\    a,
        \\    pub fn next(self: *Choice) Item {
        \\        _ = self;
        \\        return .{};
        \\    }
        \\};
        \\pub var counter: u32 = 0;
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
}

test "a scenario takes a pointer to a context type ending in ScenarioContext however it is spelled" {
    const findings = try find(
        \\const sim = @import("sim");
        \\pub fn plain(context: *sim.ScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
        \\pub fn bare(context: *ScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
        \\pub fn deep(c: *framework.sim.ScenarioContext) anyerror!void {
        \\    _ = c;
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), findings.scenarios.len);
    try std.testing.expectEqualStrings("plain", findings.scenarios[0].name);
    try std.testing.expectEqual(@as(u32, 2), findings.scenarios[0].line);
    try std.testing.expectEqualStrings("bare", findings.scenarios[1].name);
    try std.testing.expectEqualStrings("deep", findings.scenarios[2].name);
    try std.testing.expectEqual(@as(usize, 0), findings.expectations.len);
    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
}

test "an expectation function names the source file beside the sim file" {
    const findings = try find(
        \\pub fn rowsMatchLinks(context: *sim.ExpectationContext) anyerror!void {
        \\    _ = context;
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), findings.expectations.len);
    try std.testing.expectEqualStrings("rowsMatchLinks", findings.expectations[0].name);
    try std.testing.expectEqualStrings("src/thing.zig", findings.expectations[0].source_file);
    try std.testing.expectEqual(@as(u32, 1), findings.expectations[0].line);
    try std.testing.expectEqual(@as(usize, 0), findings.scenarios.len);
}

test "a scenario and an expectation function side by side are told apart" {
    const findings = try find(
        \\const sim = @import("sim");
        \\
        \\pub fn runsTwice(context: *sim.ScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
        \\
        \\pub fn stateIsValid(context: *sim.ExpectationContext) anyerror!void {
        \\    _ = context;
        \\}
        \\
        \\pub fn working() Item {
        \\    return .{};
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), findings.scenarios.len);
    try std.testing.expectEqualStrings("runsTwice", findings.scenarios[0].name);
    try std.testing.expectEqual(@as(usize, 1), findings.expectations.len);
    try std.testing.expectEqualStrings("stateIsValid", findings.expectations[0].name);
    try std.testing.expectEqual(@as(usize, 1), findings.factories.len);
    try std.testing.expectEqualStrings("working", findings.factories[0].name);
}

test "a function with the wrong signature is neither a scenario nor an expectation function" {
    const findings = try find(
        \\pub fn wrongReturn(context: *sim.ScenarioContext) void {
        \\    _ = context;
        \\}
        \\pub fn byValue(context: sim.ScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
        \\pub fn twoParameters(context: *sim.ScenarioContext, extra: u32) anyerror!void {
        \\    _ = context;
        \\    _ = extra;
        \\}
        \\pub fn noParameters() anyerror!void {}
        \\pub fn otherContext(context: *sim.OtherContext) anyerror!void {
        \\    _ = context;
        \\}
        \\pub fn glued(context: *sim.MyScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
        \\fn hidden(context: *sim.ScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
    );
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), findings.scenarios.len);
    try std.testing.expectEqual(@as(usize, 0), findings.expectations.len);
    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
}

test "a sim file with nothing in it gives empty lists" {
    const findings = try find("const sim = @import(\"sim\");\n");
    defer findings.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), findings.factories.len);
    try std.testing.expectEqual(@as(usize, 0), findings.scenarios.len);
    try std.testing.expectEqual(@as(usize, 0), findings.expectations.len);
}

test "source that does not parse is an error" {
    try std.testing.expectError(error.SourceDoesNotParse, find("pub fn ((("));
}

test "a path that is not a sim file is an error" {
    try std.testing.expectError(error.NotASimFile, finders.findIn(std.testing.allocator, "", "src/thing.zig"));
    try std.testing.expectError(error.NotASimFile, finders.findIn(std.testing.allocator, "", ".sim.zig"));
}

test "sourcePathOf drops sim from the name and keeps the directory" {
    const path = try finders.sourcePathOf(std.testing.allocator, "a/b/git.sim.zig");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("a/b/git.zig", path);

    const bare = try finders.sourcePathOf(std.testing.allocator, "git.sim.zig");
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("git.zig", bare);
}

test "memory is released when finding runs out of it part way" {
    const source =
        \\pub fn working() Item {
        \\    return .{};
        \\}
        \\pub fn check(context: *sim.ExpectationContext) anyerror!void {
        \\    _ = context;
        \\}
        \\pub fn run(context: *sim.ScenarioContext) anyerror!void {
        \\    _ = context;
        \\}
    ;
    var index: usize = 0;
    while (index < 30) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const result = finders.findIn(failing.allocator(), source, "src/thing.sim.zig");
        if (result) |findings| {
            findings.deinit(failing.allocator());
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
