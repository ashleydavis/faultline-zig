const std = @import("std");
const call_specs = @import("call_specs.zig");

const Choice = call_specs.Choice;

fn boundary(index: u32) Choice {
    return .{ .source = .boundary, .index = index };
}

fn listOf(allocator: std.mem.Allocator, count: u32) ![]const Choice {
    const list = try allocator.alloc(Choice, count);
    for (list, 0..) |*choice, index| {
        choice.* = boundary(@intCast(index));
    }
    return list;
}

test "a function with no parameters has one specification with no choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const specs = try call_specs.generateSpecs(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 1), specs.len);
    try std.testing.expectEqual(@as(usize, 0), specs[0].len);
}

test "the baseline is every parameter at its first choice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        &.{ .{ .source = .factory, .index = 0 }, .{ .source = .factory, .index = 1 } },
        &.{ boundary(0), boundary(1) },
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    try std.testing.expectEqual(Choice{ .source = .factory, .index = 0 }, specs[0][0]);
    try std.testing.expectEqual(boundary(0), specs[0][1]);
}

test "every other choice of each parameter follows with the others at their baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 3),
        try listOf(arena.allocator(), 2),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    // The baseline, three single changes and two combinations (two choices of the first with the one of the second).
    try std.testing.expectEqual(@as(usize, 1 + 3 + 2), specs.len);
    try std.testing.expect(call_specs.isSameSpec(specs[1], &.{ boundary(1), boundary(0) }));
    try std.testing.expect(call_specs.isSameSpec(specs[2], &.{ boundary(2), boundary(0) }));
    try std.testing.expect(call_specs.isSameSpec(specs[3], &.{ boundary(0), boundary(1) }));
}

test "combinations change two parameters at once and come after the single changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 3),
        try listOf(arena.allocator(), 3),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    // The baseline, four single changes, then the four pairs of non-baseline choices.
    try std.testing.expectEqual(@as(usize, 1 + 4 + 4), specs.len);
    for (specs[5..]) |spec| {
        try std.testing.expect(spec[0].index != 0 and spec[1].index != 0);
    }
}

test "every combination of every choice of every parameter is tried" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 3),
        try listOf(arena.allocator(), 4),
        try listOf(arena.allocator(), 5),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    try std.testing.expectEqual(@as(usize, 3 * 4 * 5), specs.len);
}

test "combinations change three parameters at once as well as two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 2),
        try listOf(arena.allocator(), 2),
        try listOf(arena.allocator(), 2),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    var found = false;
    for (specs) |spec| {
        if (call_specs.isSameSpec(spec, &.{ boundary(1), boundary(1), boundary(1) })) {
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "the last choices of a parameter take part in combinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 20),
        try listOf(arena.allocator(), 20),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    try std.testing.expect(call_specs.isSameSpec(specs[specs.len - 1], &.{ boundary(19), boundary(19) }));
}

test "no specification repeats another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 6),
        try listOf(arena.allocator(), 5),
        try listOf(arena.allocator(), 4),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    for (specs, 0..) |spec, index| {
        for (specs[index + 1 ..]) |later| {
            try std.testing.expect(!call_specs.isSameSpec(spec, later));
        }
    }
}

test "the same lists always give the same specifications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 5),
        try listOf(arena.allocator(), 5),
    };
    const first = try call_specs.generateSpecs(arena.allocator(), &lists);
    const second = try call_specs.generateSpecs(arena.allocator(), &lists);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |one, other| {
        try std.testing.expect(call_specs.isSameSpec(one, other));
    }
}

test "a parameter with no choice means the function cannot be called" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{ try listOf(arena.allocator(), 2), &.{} };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    try std.testing.expectEqual(@as(usize, 0), specs.len);
}

test "a parameter with one choice contributes no change and no combination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{ try listOf(arena.allocator(), 1), try listOf(arena.allocator(), 3) };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    try std.testing.expectEqual(@as(usize, 3), specs.len);
}

test "isSameSpec compares source and index and length" {
    try std.testing.expect(call_specs.isSameSpec(&.{boundary(1)}, &.{boundary(1)}));
    try std.testing.expect(!call_specs.isSameSpec(&.{boundary(1)}, &.{boundary(2)}));
    try std.testing.expect(!call_specs.isSameSpec(&.{boundary(1)}, &.{.{ .source = .seeded, .index = 1 }}));
    try std.testing.expect(!call_specs.isSameSpec(&.{boundary(1)}, &.{ boundary(1), boundary(1) }));
}
