const std = @import("std");
const shards = @import("shards.zig");
const worker = @import("worker.zig");

fn function(index: usize) worker.WorkItem {
    return .{ .function = .{ .index = index, .phase = .normal } };
}

test "no items make no shards" {
    const made = try shards.split(std.testing.allocator, &.{}, &.{});
    defer shards.free(std.testing.allocator, made);

    try std.testing.expectEqual(@as(usize, 0), made.len);
}

test "the items of one file make one shard in their order" {
    const items = [_]worker.WorkItem{ function(3), function(1), function(2) };
    const files = [_][]const u8{ "a.zig", "a.zig", "a.zig" };
    const made = try shards.split(std.testing.allocator, &items, &files);
    defer shards.free(std.testing.allocator, made);

    try std.testing.expectEqual(@as(usize, 1), made.len);
    try std.testing.expectEqual(@as(usize, 3), made[0][0].function.index);
    try std.testing.expectEqual(@as(usize, 1), made[0][1].function.index);
    try std.testing.expectEqual(@as(usize, 2), made[0][2].function.index);
}

test "the items of interleaved files are grouped by file in the order each file first appears" {
    const items = [_]worker.WorkItem{ function(0), function(1), function(2), .{ .scenario = 0 }, function(3) };
    const files = [_][]const u8{ "b.zig", "a.zig", "b.zig", "a.sim.zig", "a.zig" };
    const made = try shards.split(std.testing.allocator, &items, &files);
    defer shards.free(std.testing.allocator, made);

    try std.testing.expectEqual(@as(usize, 3), made.len);
    try std.testing.expectEqual(@as(usize, 2), made[0].len);
    try std.testing.expectEqual(@as(usize, 0), made[0][0].function.index);
    try std.testing.expectEqual(@as(usize, 2), made[0][1].function.index);
    try std.testing.expectEqual(@as(usize, 1), made[1][0].function.index);
    try std.testing.expectEqual(@as(usize, 3), made[1][1].function.index);
    try std.testing.expectEqual(@as(usize, 0), made[2][0].scenario);
}

test "the same items make the same shards every time" {
    const items = [_]worker.WorkItem{ function(0), function(1), function(2) };
    const files = [_][]const u8{ "b.zig", "a.zig", "b.zig" };
    const first = try shards.split(std.testing.allocator, &items, &files);
    defer shards.free(std.testing.allocator, first);
    const second = try shards.split(std.testing.allocator, &items, &files);
    defer shards.free(std.testing.allocator, second);

    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |one, other| {
        try std.testing.expectEqual(one.len, other.len);
        for (one, other) |item, same| {
            try std.testing.expectEqual(item.function.index, same.function.index);
        }
    }
}
