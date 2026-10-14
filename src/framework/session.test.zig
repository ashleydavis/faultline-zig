const std = @import("std");
const session_mod = @import("session.zig");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector = @import("injector.zig");
const filesystem = @import("filesystem.zig");

fn kindIndex(effect: point.Effect, id: []const u8) u8 {
    for (failures.kindsOf(effect), 0..) |kind, index| {
        if (std.mem.eql(u8, kind.id, id)) {
            return @intCast(index);
        }
    }
    unreachable;
}

test "a session lets an allocation through and records the place" {
    var session: session_mod.Session = .{ .injector = undefined };
    try session.begin(std.testing.allocator, std.testing.io, &.{}, 1);
    defer session.end();

    const memory = try session.allocator().alloc(u8, 16);
    session.allocator().free(memory);

    try std.testing.expect(session.places().len >= 1);
    try std.testing.expectEqual(point.Effect.allocator, session.places()[0].point.effect);
}

test "a session fails the allocation its plan names" {
    const plan = [_]injector.Injection{.{
        .point = .{ .effect = .allocator, .occurrence = 0 },
        .kind = kindIndex(.allocator, "allocation_fails"),
    }};
    var session: session_mod.Session = .{ .injector = undefined };
    try session.begin(std.testing.allocator, std.testing.io, &plan, 1);
    defer session.end();

    try std.testing.expectError(error.OutOfMemory, session.allocator().alloc(u8, 16));
}

test "a session's Io writes into the simulated filesystem and not the disk" {
    var session: session_mod.Session = .{ .injector = undefined };
    try session.begin(std.testing.allocator, std.testing.io, &.{}, 1);
    defer session.end();

    try std.Io.Dir.cwd().writeFile(session.io, .{ .sub_path = "note.txt", .data = "hello" });

    const contents = try filesystem.readContents(std.testing.allocator, "note.txt");
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("hello", contents);
    std.Io.Dir.cwd().access(std.testing.io, "note.txt", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.TestUnexpectedResult;
}

test "beginning a second session forgets what the first left in the filesystem" {
    var first: session_mod.Session = .{ .injector = undefined };
    try first.begin(std.testing.allocator, std.testing.io, &.{}, 1);
    try filesystem.makeFile("left-behind.txt", "x");
    first.end();

    var second: session_mod.Session = .{ .injector = undefined };
    try second.begin(std.testing.allocator, std.testing.io, &.{}, 1);
    defer second.end();

    try std.testing.expect(!filesystem.exists("left-behind.txt"));
}

test "a session's random source gives the same bytes for the same seed" {
    var a: session_mod.Session = .{ .injector = undefined };
    try a.begin(std.testing.allocator, std.testing.io, &.{}, 42);
    const first = a.random().int(u64);
    a.end();

    var b: session_mod.Session = .{ .injector = undefined };
    try b.begin(std.testing.allocator, std.testing.io, &.{}, 42);
    defer b.end();

    try std.testing.expectEqual(first, b.random().int(u64));
}

test "a session's writer accepts bytes and keeps them" {
    var session: session_mod.Session = .{ .injector = undefined };
    try session.begin(std.testing.allocator, std.testing.io, &.{}, 1);
    defer session.end();

    try session.writer.interface.writeAll("abc");

    try std.testing.expectEqualStrings("abc", session.writer.written());
}
