const std = @import("std");
const sim = @import("sim.zig");

// The writer the contexts below hold. These tests never write to it.
var unused_writer: std.Io.Writer = .failing;

fn contextFor(faults: *sim.Faults) sim.ScenarioContext {
    return .{
        .faults = faults,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .writer = &unused_writer,
    };
}

test "a true expectation in a scenario records nothing and returns no error" {
    var faults: sim.Faults = .{};
    var context = contextFor(&faults);

    try context.expect(@src(), true, "one to be one");

    try std.testing.expect(context.failed == null);
}

test "a false expectation in a scenario records where it was written and what it said" {
    var faults: sim.Faults = .{};
    var context = contextFor(&faults);

    const result = context.expect(@src(), false, "one to be two");

    try std.testing.expectError(error.ExpectationFailed, result);
    const failed = context.failed.?;
    try std.testing.expectEqualStrings("one to be two", failed.text);
    try std.testing.expect(std.mem.endsWith(u8, failed.file, "sim.test.zig"));
    try std.testing.expect(failed.line > 0);
}

test "a true expectation in an expectation function records nothing and returns no error" {
    var context: sim.ExpectationContext = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };

    try context.expect(@src(), true, "one to be one");

    try std.testing.expect(context.failed == null);
}

test "a false expectation in an expectation function records where it was written and what it said" {
    var context: sim.ExpectationContext = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };

    const result = context.expect(@src(), false, "one to be two");

    try std.testing.expectError(error.ExpectationFailed, result);
    try std.testing.expectEqualStrings("one to be two", context.failed.?.text);
}

test "a new Faults control has injected nothing" {
    const faults: sim.Faults = .{};

    try std.testing.expectEqual(@as(usize, 0), faults.injected);
}
