const std = @import("std");
const report = @import("report.zig");
const worker = @import("worker.zig");
const output_mod = @import("output.zig");

fn printed(allocator: std.mem.Allocator, failure: worker.Failure, subject: []const u8) ![]u8 {
    var captured: std.Io.Writer.Allocating = .init(allocator);
    defer captured.deinit();
    output_mod.writer = &captured.writer;
    defer output_mod.writer = null;
    report.printFailure(failure, subject);
    return allocator.dupe(u8, captured.written());
}

test "a crash names the function and says what the child said" {
    const text = try printed(std.testing.allocator, .{
        .is_scenario = false,
        .index = 0,
        .kind = .crash,
        .token = "a.zig:f;seed=1",
        .complaint = "reached unreachable code",
    }, "parseHeader");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "The call to parseHeader crashed: reached unreachable code") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Reproduce it with: zig build flt -Dreplay=\"a.zig:f;seed=1\"") != null);
}

test "a crash with nothing said still names the function" {
    const text = try printed(std.testing.allocator, .{ .is_scenario = false, .index = 0, .kind = .crash, .token = "t" }, "run");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "The call to run crashed.") != null);
}

test "a hang says the call did not return in time" {
    const text = try printed(std.testing.allocator, .{ .is_scenario = false, .index = 0, .kind = .hang, .token = "t" }, "spin");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "The call to spin did not return in time.") != null);
}

test "a false expectation in a scenario names the scenario, the text and the line" {
    const text = try printed(std.testing.allocator, .{
        .is_scenario = true,
        .index = 0,
        .kind = .expectation,
        .token = "t",
        .file = "total.sim.zig",
        .line = 18,
        .text = "the total to be twice the amount",
    }, "runAddingUpScenario");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "The scenario runAddingUpScenario expected the total to be twice the amount, at total.sim.zig:18.") != null);
}

test "a false expectation function names the function it ran after" {
    const text = try printed(std.testing.allocator, .{
        .is_scenario = false,
        .index = 0,
        .kind = .expectation,
        .token = "t",
        .expectation_function = "totalIsNeverNegative",
        .file = "total.sim.zig",
        .line = 9,
        .text = "the total to stay at or above zero",
    }, "addAmount");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "The expectation function totalIsNeverNegative expected the total to stay at or above zero, at total.sim.zig:9, after the call to addAmount.") != null);
}

fn countsOf(allocator: std.mem.Allocator, failures: []const worker.Failure) ![]u8 {
    var written: std.Io.Writer.Allocating = .init(allocator);
    defer written.deinit();
    try report.writeFailureCounts(&written.writer, failures);
    return allocator.dupe(u8, written.written());
}

test "writeFailureCounts counts each kind of failure and the functions and scenarios it is in" {
    const failures = [_]worker.Failure{
        .{ .is_scenario = false, .index = 0, .kind = .crash, .token = "a" },
        .{ .is_scenario = false, .index = 0, .kind = .crash, .token = "b" },
        .{ .is_scenario = false, .index = 3, .kind = .crash, .token = "c" },
        .{ .is_scenario = true, .index = 0, .kind = .expectation, .token = "d" },
        .{ .is_scenario = true, .index = 2, .kind = .crash, .token = "e" },
    };
    const text = try countsOf(std.testing.allocator, &failures);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("  4 calls crashed, in 2 functions and 1 scenario.\n  1 expectation was false, in 1 scenario.\n", text);
}

test "writeFailureCounts says so when nothing failed" {
    const text = try countsOf(std.testing.allocator, &.{});
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("  No call crashed, hung or found an expectation false.\n", text);
}
