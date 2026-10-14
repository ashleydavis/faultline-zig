const std = @import("std");
const plan_mod = @import("plan.zig");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector = @import("injector.zig");

fn kindIndex(effect: point.Effect, id: []const u8) u8 {
    for (failures.kindsOf(effect), 0..) |kind, index| {
        if (std.mem.eql(u8, kind.id, id)) {
            return @intCast(index);
        }
    }
    unreachable;
}

fn textOf(allocator: std.mem.Allocator, plan: plan_mod.Plan) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    errdefer buffer.deinit();
    try buffer.writer.print("{f}", .{plan});
    return buffer.toOwnedSlice();
}

test "a plan with only a function and a seed prints and reads back" {
    const plan: plan_mod.Plan = .{
        .file = "src/lib/git.zig",
        .function = "parseUrl",
        .seed = 99,
        .choices = &.{},
        .injections = &.{},
    };
    const text = try textOf(std.testing.allocator, plan);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("src/lib/git.zig:parseUrl;seed=99", text);

    var read = try plan_mod.parse(std.testing.allocator, text);
    defer read.deinit();
    try std.testing.expect(plan.eql(read));
}

test "a plan with values and failures round trips through text" {
    const injections = [_]injector.Injection{
        .{ .point = .{ .effect = .read, .occurrence = 1 }, .kind = kindIndex(.read, "short_read") },
        .{ .point = .{ .effect = .allocator, .occurrence = 0 }, .kind = kindIndex(.allocator, "allocation_fails") },
    };
    const choices = [_]plan_mod.Choice{
        .{ .source = .boundary, .index = 3 },
        .{ .source = .factory, .index = 0 },
        .{ .source = .condition, .index = 12 },
        .{ .source = .seeded, .index = 1 },
    };
    const plan: plan_mod.Plan = .{
        .file = "a/b.zig",
        .function = "Counter.bump",
        .seed = 18446744073709551615,
        .choices = &choices,
        .injections = &injections,
    };
    const text = try textOf(std.testing.allocator, plan);
    defer std.testing.allocator.free(text);

    var read = try plan_mod.parse(std.testing.allocator, text);
    defer read.deinit();

    try std.testing.expect(plan.eql(read));
    try std.testing.expectEqualStrings("Counter.bump", read.function);
}

test "two plans that differ in one injection are not equal" {
    const a = [_]injector.Injection{.{ .point = .{ .effect = .read, .occurrence = 1 }, .kind = 0 }};
    const b = [_]injector.Injection{.{ .point = .{ .effect = .read, .occurrence = 2 }, .kind = 0 }};
    const one: plan_mod.Plan = .{ .file = "f.zig", .function = "g", .seed = 1, .choices = &.{}, .injections = &a };
    const two: plan_mod.Plan = .{ .file = "f.zig", .function = "g", .seed = 1, .choices = &.{}, .injections = &b };

    try std.testing.expect(!one.eql(two));
}

test "a token with no function is refused" {
    try std.testing.expectError(error.NoFunction, plan_mod.parse(std.testing.allocator, "seed=1"));
    try std.testing.expectError(error.NoFunction, plan_mod.parse(std.testing.allocator, ":run;seed=1"));
}

test "a token with an unknown part is refused" {
    try std.testing.expectError(error.BadPart, plan_mod.parse(std.testing.allocator, "a.zig:f;speed=1"));
}

test "a token with a bad seed is refused" {
    try std.testing.expectError(error.BadSeed, plan_mod.parse(std.testing.allocator, "a.zig:f;seed=many"));
}

test "a token with a bad choice is refused" {
    try std.testing.expectError(error.BadChoice, plan_mod.parse(std.testing.allocator, "a.zig:f;seed=1;values=x3"));
    try std.testing.expectError(error.BadChoice, plan_mod.parse(std.testing.allocator, "a.zig:f;seed=1;values=b"));
}

test "a token naming an unknown effect or failure is refused" {
    try std.testing.expectError(error.UnknownEffect, plan_mod.parse(std.testing.allocator, "a.zig:f;seed=1;fail=teleport#0/x"));
    try std.testing.expectError(error.UnknownFailure, plan_mod.parse(std.testing.allocator, "a.zig:f;seed=1;fail=read#0/x"));
    try std.testing.expectError(error.BadFailure, plan_mod.parse(std.testing.allocator, "a.zig:f;seed=1;fail=read"));
}
