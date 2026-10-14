const std = @import("std");
const point = @import("point.zig");
const injector = @import("injector.zig");
const wire = @import("wire.zig");

fn roundTrip(result: wire.Result, places: []const injector.Place) !wire.Report {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();
    try wire.write(&buffer.writer, result, places);
    return wire.read(std.testing.allocator, buffer.written());
}

test "a call that returned reads back as returned with no places" {
    var report = try roundTrip(.returned, &.{});
    defer report.deinit();

    try std.testing.expect(report.result.? == .returned);
    try std.testing.expectEqual(@as(usize, 0), report.places.len);
}

test "a call that returned an error reads back with the error name" {
    var report = try roundTrip(.{ .errored = "FileNotFound" }, &.{});
    defer report.deinit();

    try std.testing.expectEqualStrings("FileNotFound", report.result.?.errored);
}

test "a false expectation reads back with its function, file, line and text" {
    const failure: wire.ExpectationFailure = .{
        .function = "rowsAndLinksAgree",
        .file = "src/lib/links.sim.zig",
        .line = 42,
        .text = "every row\tto have its link\nand more \\ here",
    };
    var report = try roundTrip(.{ .expectation_failed = failure }, &.{});
    defer report.deinit();

    const read = report.result.?.expectation_failed;
    try std.testing.expectEqualStrings(failure.function, read.function);
    try std.testing.expectEqualStrings(failure.file, read.file);
    try std.testing.expectEqual(failure.line, read.line);
    try std.testing.expectEqualStrings(failure.text, read.text);
}

test "places read back in order with their effect, occurrence and kinds" {
    const kinds_a = [_]u8{ 0, 3, 5 };
    const kinds_b = [_]u8{};
    const places = [_]injector.Place{
        .{ .point = .{ .effect = .read, .occurrence = 0 }, .kinds = &kinds_a },
        .{ .point = .{ .effect = .allocator, .occurrence = 7 }, .kinds = &kinds_b },
    };
    var report = try roundTrip(.returned, &places);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.places.len);
    try std.testing.expect(report.places[0].point.eql(.{ .effect = .read, .occurrence = 0 }));
    try std.testing.expectEqualSlices(u8, &kinds_a, report.places[0].kinds);
    try std.testing.expect(report.places[1].point.eql(.{ .effect = .allocator, .occurrence = 7 }));
    try std.testing.expectEqual(@as(usize, 0), report.places[1].kinds.len);
}

test "a report cut short is read as far as it goes" {
    var report = try wire.read(std.testing.allocator, "R\treturned\nP\tread\t0\t1,2\nP\twri");
    defer report.deinit();

    try std.testing.expect(report.result.? == .returned);
    try std.testing.expectEqual(@as(usize, 1), report.places.len);
}

test "a line that is not understood is passed over" {
    var report = try wire.read(std.testing.allocator, "nonsense\nX\ty\nR\treturned\n");
    defer report.deinit();

    try std.testing.expect(report.result.? == .returned);
}

test "an empty report has no result, which is what a crash looks like" {
    var report = try wire.read(std.testing.allocator, "");
    defer report.deinit();

    try std.testing.expect(report.result == null);
}
