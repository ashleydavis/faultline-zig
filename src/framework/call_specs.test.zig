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

test "combinations visit every pair of parameters before repeating any" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 3),
        try listOf(arena.allocator(), 3),
        try listOf(arena.allocator(), 3),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    const first_combination = 1 + 6;
    // The first three combinations are the first choice of each pair of parameters.
    try std.testing.expect(call_specs.isSameSpec(specs[first_combination], &.{ boundary(1), boundary(1), boundary(0) }));
    try std.testing.expect(call_specs.isSameSpec(specs[first_combination + 1], &.{ boundary(1), boundary(0), boundary(1) }));
    try std.testing.expect(call_specs.isSameSpec(specs[first_combination + 2], &.{ boundary(0), boundary(1), boundary(1) }));
}

test "combinations stop at the limit however many parameters and choices there are" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lists: [8][]const Choice = undefined;
    for (&lists) |*list| {
        list.* = try listOf(arena.allocator(), 10);
    }
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    const singles = 1 + 8 * 9;
    try std.testing.expectEqual(singles + call_specs.max_combination_specs, specs.len);
}

test "only the first few choices of a parameter take part in combinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lists = [_][]const Choice{
        try listOf(arena.allocator(), 20),
        try listOf(arena.allocator(), 20),
    };
    const specs = try call_specs.generateSpecs(arena.allocator(), &lists);
    const singles = 1 + 19 + 19;
    try std.testing.expectEqual(singles + call_specs.combination_choices_per_parameter * call_specs.combination_choices_per_parameter, specs.len);
    for (specs[singles..]) |spec| {
        try std.testing.expect(spec[0].index <= call_specs.combination_choices_per_parameter);
        try std.testing.expect(spec[1].index <= call_specs.combination_choices_per_parameter);
    }
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
