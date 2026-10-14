const std = @import("std");
const condition = @import("condition.zig");
const candidates = @import("candidates.zig");

fn comparison(literal: condition.Literal) condition.Condition {
    return .{ .line = 1, .kind = .comparison, .operator = .greater, .literal = literal, .subject = "value" };
}

fn textCondition(kind: condition.Kind, text: []const u8) condition.Condition {
    return .{ .line = 1, .kind = kind, .literal = .{ .string = text }, .subject = "name" };
}

test "an integer literal gives itself, one below and one above" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(i32, arena.allocator(), &.{comparison(.{ .int = 100 })});
    try std.testing.expectEqualSlices(i32, &.{ 100, 99, 101 }, found);
}

test "integer candidates the type cannot hold are left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(u8, arena.allocator(), &.{ comparison(.{ .int = 0 }), comparison(.{ .int = 255 }), comparison(.{ .int = 1000 }) });
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 255, 254 }, found);
}

test "integer candidates at the edge of the widest type do not overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(i128, arena.allocator(), &.{comparison(.{ .int = std.math.maxInt(i128) })});
    try std.testing.expectEqualSlices(i128, &.{ std.math.maxInt(i128), std.math.maxInt(i128) - 1 }, found);
}

test "a literal repeated by two conditions gives one candidate each" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(i32, arena.allocator(), &.{ comparison(.{ .int = 5 }), comparison(.{ .int = 5 }), comparison(.{ .int = 6 }) });
    try std.testing.expectEqualSlices(i32, &.{ 5, 4, 6, 7 }, found);
}

test "a switch prong with an integer literal is a candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prong: condition.Condition = .{ .line = 4, .kind = .switch_prong, .literal = .{ .int = 7 } };
    const found = try candidates.candidatesFor(u16, arena.allocator(), &.{prong});
    try std.testing.expectEqualSlices(u16, &.{ 7, 6, 8 }, found);
}

test "a float literal gives itself and the next number on each side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(f64, arena.allocator(), &.{comparison(.{ .float = 90.0 })});
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqual(@as(f64, 90.0), found[0]);
    try std.testing.expect(found[1] < 90.0 and found[1] > 89.999999);
    try std.testing.expect(found[2] > 90.0 and found[2] < 90.000001);
}

test "an integer literal compared against a float is taken as that float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(f32, arena.allocator(), &.{comparison(.{ .int = 3 })});
    try std.testing.expectEqual(@as(f32, 3.0), found[0]);
    try std.testing.expectEqual(@as(usize, 3), found.len);
}

test "a float literal gives no integer candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(i32, arena.allocator(), &.{comparison(.{ .float = 2.5 })});
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a string equality gives the literal and a near miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor([]const u8, arena.allocator(), &.{textCondition(.string_equals, "stop")});
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("stop", found[0]);
    try std.testing.expectEqual(@as(usize, 4), found[1].len);
    try std.testing.expect(!std.mem.eql(u8, found[0], found[1]));
}

test "a prefix test also gives strings that start with the literal and with the near miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.stringCandidates(arena.allocator(), &.{textCondition(.string_starts_with, "http://")});
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualStrings("http://", found[0]);
    try std.testing.expect(std.mem.startsWith(u8, found[2], "http://") and found[2].len > 7);
    try std.testing.expect(!std.mem.startsWith(u8, found[3], "http://"));
    try std.testing.expect(std.mem.startsWith(u8, found[3], found[1]));
}

test "a suffix test also gives strings that end with the literal and with the near miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.stringCandidates(arena.allocator(), &.{textCondition(.string_ends_with, ".zig")});
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualStrings(".zig", found[0]);
    try std.testing.expect(std.mem.endsWith(u8, found[2], ".zig") and found[2].len > 4);
    try std.testing.expect(!std.mem.endsWith(u8, found[3], ".zig"));
    try std.testing.expect(std.mem.endsWith(u8, found[3], found[1]));
}

test "the near miss of the empty string is one letter and of any other string differs in the last byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const empty = try candidates.nearMiss(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 1), empty.len);
    const other = try candidates.nearMiss(arena.allocator(), "abc");
    try std.testing.expectEqualStrings("ab", other[0..2]);
    try std.testing.expect(other[2] != 'c');
}

test "a string literal that is empty still gives two different strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.stringCandidates(arena.allocator(), &.{textCondition(.string_equals, "")});
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("", found[0]);
    try std.testing.expect(found[1].len == 1);
}

test "string candidates carry the sentinel when the type has one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor([:0]const u8, arena.allocator(), &.{textCondition(.string_equals, "go")});
    try std.testing.expectEqualStrings("go", found[0]);
    try std.testing.expectEqual(@as(u8, 0), found[0][found[0].len]);
}

test "an enum gets each tag a condition names and ignores a name it does not have" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Mode = enum { fast, slow, off };
    const named = [_]condition.Condition{
        .{ .line = 1, .kind = .switch_prong, .literal = .{ .enum_tag = "slow" } },
        .{ .line = 2, .kind = .comparison, .operator = .equal, .literal = .{ .enum_tag = "fast" } },
        .{ .line = 3, .kind = .switch_prong, .literal = .{ .enum_tag = "missing" } },
        .{ .line = 4, .kind = .switch_prong, .literal = .{ .enum_tag = "slow" } },
    };
    const found = try candidates.candidatesFor(Mode, arena.allocator(), &named);
    try std.testing.expectEqualSlices(Mode, &.{ .slow, .fast }, found);
}

test "a boolean always gets both values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(bool, arena.allocator(), &.{});
    try std.testing.expectEqualSlices(bool, &.{ false, true }, found);
}

test "an optional gets null first and then what it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(?u8, arena.allocator(), &.{comparison(.{ .int = 10 })});
    try std.testing.expectEqualSlices(?u8, &.{ null, 10, 9, 11 }, found);
}

test "an optional with only a null test gets null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const check: condition.Condition = .{ .line = 2, .kind = .optional_check, .subject = "name" };
    const found = try candidates.candidatesFor(?[]const u8, arena.allocator(), &.{check});
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0] == null);
}

test "an optional with no condition about it or what it holds has no list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(?u8, arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "an optional string gets null then the strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const found = try candidates.candidatesFor(?[]const u8, arena.allocator(), &.{textCondition(.string_equals, "x")});
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expect(found[0] == null);
    try std.testing.expectEqualStrings("x", found[1].?);
}

test "a type with no candidates gets an empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Pair = struct { a: u8, b: u8 };
    const conditions = [_]condition.Condition{comparison(.{ .int = 3 })};
    try std.testing.expectEqual(@as(usize, 0), (try candidates.candidatesFor(Pair, arena.allocator(), &conditions)).len);
    try std.testing.expectEqual(@as(usize, 0), (try candidates.candidatesFor([]u8, arena.allocator(), &conditions)).len);
    try std.testing.expectEqual(@as(usize, 0), (try candidates.candidatesFor([]const u32, arena.allocator(), &conditions)).len);
}

test "a literal of the wrong kind for the type is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const mixed = [_]condition.Condition{ textCondition(.string_equals, "x"), comparison(.{ .int = 4 }), comparison(.{ .boolean = true }) };
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 5 }, try candidates.candidatesFor(u8, arena.allocator(), &mixed));
    try std.testing.expectEqual(@as(usize, 2), (try candidates.stringCandidates(arena.allocator(), &mixed)).len);
}

test "the same conditions always give the same list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const conditions = [_]condition.Condition{ comparison(.{ .int = 50 }), comparison(.{ .int = 7 }), comparison(.{ .int = 50 }) };
    const first = try candidates.candidatesFor(i64, arena.allocator(), &conditions);
    const second = try candidates.candidatesFor(i64, arena.allocator(), &conditions);
    try std.testing.expectEqualSlices(i64, first, second);
    for (first, 0..) |value, index| {
        for (first[index + 1 ..]) |later| {
            try std.testing.expect(value != later);
        }
    }
}

test "isCandidateType is true for the types that can have candidates" {
    try std.testing.expect(candidates.isCandidateType(u8));
    try std.testing.expect(candidates.isCandidateType(f32));
    try std.testing.expect(candidates.isCandidateType(bool));
    try std.testing.expect(candidates.isCandidateType(enum { a }));
    try std.testing.expect(candidates.isCandidateType(?u8));
    try std.testing.expect(candidates.isCandidateType([]const u8));
    try std.testing.expect(candidates.isCandidateType([:0]const u8));
    try std.testing.expect(!candidates.isCandidateType([]u8));
    try std.testing.expect(!candidates.isCandidateType(struct { a: u8 }));
    try std.testing.expect(!candidates.isCandidateType([]const u32));
}
