const std = @import("std");
const point = @import("point.zig");

test "two points are equal when the effect and the occurrence are the same" {
    const a: point.Point = .{ .effect = .read, .occurrence = 2 };
    const b: point.Point = .{ .effect = .read, .occurrence = 2 };

    try std.testing.expect(a.eql(b));
}

test "two points are not equal when the effect differs" {
    const a: point.Point = .{ .effect = .read, .occurrence = 2 };
    const b: point.Point = .{ .effect = .write, .occurrence = 2 };

    try std.testing.expect(!a.eql(b));
}

test "two points are not equal when the occurrence differs" {
    const a: point.Point = .{ .effect = .read, .occurrence = 2 };
    const b: point.Point = .{ .effect = .read, .occurrence = 3 };

    try std.testing.expect(!a.eql(b));
}

test "a point formats as the effect, a hash and the occurrence" {
    const a: point.Point = .{ .effect = .file_open, .occurrence = 4 };

    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.print("{f}", .{a});

    try std.testing.expectEqualStrings("file_open#4", writer.buffered());
}
