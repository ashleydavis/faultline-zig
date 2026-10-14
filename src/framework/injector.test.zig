const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector = @import("injector.zig");

const read_kinds = [_]u8{ 0, 1 };

test "an injector with an empty plan fails nothing" {
    var inj = injector.Injector.init(std.testing.allocator, &.{});
    defer inj.deinit();

    try std.testing.expectEqual(@as(?u8, null), inj.check(.read, &read_kinds));
    try std.testing.expectEqual(@as(?u8, null), inj.check(.read, &read_kinds));
}

test "an injector records every place it is asked about in order" {
    var inj = injector.Injector.init(std.testing.allocator, &.{});
    defer inj.deinit();

    _ = inj.check(.read, &read_kinds);
    _ = inj.check(.write, &read_kinds);
    _ = inj.check(.read, &read_kinds);

    try std.testing.expectEqual(@as(usize, 3), inj.recorded.items.len);
    try std.testing.expect(inj.recorded.items[0].point.eql(.{ .effect = .read, .occurrence = 0 }));
    try std.testing.expect(inj.recorded.items[1].point.eql(.{ .effect = .write, .occurrence = 0 }));
    try std.testing.expect(inj.recorded.items[2].point.eql(.{ .effect = .read, .occurrence = 1 }));
    try std.testing.expectEqualSlices(u8, &read_kinds, inj.recorded.items[0].kinds);
}

test "an injector fails the planned place and no other" {
    const plan = [_]injector.Injection{.{ .point = .{ .effect = .read, .occurrence = 1 }, .kind = 1 }};
    var inj = injector.Injector.init(std.testing.allocator, &plan);
    defer inj.deinit();

    try std.testing.expectEqual(@as(?u8, null), inj.check(.read, &read_kinds));
    try std.testing.expectEqual(@as(?u8, 1), inj.check(.read, &read_kinds));
    try std.testing.expectEqual(@as(?u8, null), inj.check(.read, &read_kinds));
}

test "an injector still records the places a failing call reaches" {
    const plan = [_]injector.Injection{.{ .point = .{ .effect = .read, .occurrence = 0 }, .kind = 0 }};
    var inj = injector.Injector.init(std.testing.allocator, &plan);
    defer inj.deinit();

    _ = inj.check(.read, &read_kinds);
    _ = inj.check(.write, &read_kinds);

    try std.testing.expectEqual(@as(usize, 2), inj.recorded.items.len);
}

test "an injector ignores a planned failure that cannot happen to the call" {
    const plan = [_]injector.Injection{.{ .point = .{ .effect = .read, .occurrence = 0 }, .kind = 5 }};
    var inj = injector.Injector.init(std.testing.allocator, &plan);
    defer inj.deinit();

    try std.testing.expectEqual(@as(?u8, null), inj.check(.read, &read_kinds));
}

test "reset forgets the counts and the recorded places" {
    var inj = injector.Injector.init(std.testing.allocator, &.{});
    defer inj.deinit();
    _ = inj.check(.read, &read_kinds);
    _ = inj.check(.read, &read_kinds);

    inj.reset();
    _ = inj.check(.read, &read_kinds);

    try std.testing.expectEqual(@as(usize, 1), inj.recorded.items.len);
    try std.testing.expectEqual(@as(u32, 0), inj.recorded.items[0].point.occurrence);
}

test "nameOf gives the id of the failure in the effect's table" {
    const injection: injector.Injection = .{ .point = .{ .effect = .allocator, .occurrence = 0 }, .kind = 1 };

    try std.testing.expectEqualStrings(failures.allocator_kinds[1].id, injector.Injector.nameOf(injection));
}
