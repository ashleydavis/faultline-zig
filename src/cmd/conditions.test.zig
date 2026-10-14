// Tests for the condition reader. Each feeds a snippet of Zig source and checks what was read.

const std = @import("std");
const conditions = @import("conditions.zig");
const condition = @import("../framework/condition.zig");

// Reads the conditions of one function in a snippet.
fn read(source: [:0]const u8, function_name: []const u8) ![]condition.Condition {
    return conditions.conditionsIn(std.testing.allocator, source, function_name);
}

test "an integer comparison reports the operator, the literal, the subject and the line" {
    const found = try read(
        \\fn check(count: u32) bool {
        \\    if (count > 10) {
        \\        return true;
        \\    }
        \\    return false;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(u32, 2), found[0].line);
    try std.testing.expectEqual(condition.Kind.comparison, found[0].kind);
    try std.testing.expectEqual(condition.Operator.greater, found[0].operator.?);
    try std.testing.expectEqual(@as(i128, 10), found[0].literal.?.int);
    try std.testing.expectEqualStrings("count", found[0].subject);
}

test "every comparison operator is read" {
    const found = try read(
        \\fn check(x: i32) void {
        \\    _ = x == 1;
        \\    _ = x != 2;
        \\    _ = x < 3;
        \\    _ = x <= 4;
        \\    _ = x > 5;
        \\    _ = x >= 6;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    const expected = [_]condition.Operator{ .equal, .not_equal, .less, .less_equal, .greater, .greater_equal };
    try std.testing.expectEqual(expected.len, found.len);
    for (expected, found, 1..) |operator, item, number| {
        try std.testing.expectEqual(operator, item.operator.?);
        try std.testing.expectEqual(@as(i128, @intCast(number)), item.literal.?.int);
    }
}

test "a constant on the left is read as if it were on the right" {
    const found = try read(
        \\fn check(x: i32) void {
        \\    _ = 3 < x;
        \\    _ = 4 == x;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(condition.Operator.greater, found[0].operator.?);
    try std.testing.expectEqual(@as(i128, 3), found[0].literal.?.int);
    try std.testing.expectEqualStrings("x", found[0].subject);
    try std.testing.expectEqual(condition.Operator.equal, found[1].operator.?);
}

test "a comparison with no constant on either side is not reported" {
    const found = try read(
        \\fn check(a: i32, b: i32) bool {
        \\    return a < b;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "negative, hexadecimal and character literals are integers" {
    const found = try read(
        \\fn check(x: i32, c: u8) void {
        \\    _ = x == -7;
        \\    _ = x == 0xff;
        \\    _ = c == 'a';
        \\    _ = c == '\n';
        \\    _ = x == (5);
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 5), found.len);
    try std.testing.expectEqual(@as(i128, -7), found[0].literal.?.int);
    try std.testing.expectEqual(@as(i128, 255), found[1].literal.?.int);
    try std.testing.expectEqual(@as(i128, 'a'), found[2].literal.?.int);
    try std.testing.expectEqual(@as(i128, '\n'), found[3].literal.?.int);
    try std.testing.expectEqual(@as(i128, 5), found[4].literal.?.int);
}

test "a float literal is read, negative ones too" {
    const found = try read(
        \\fn check(x: f64) void {
        \\    _ = x > 0.5;
        \\    _ = x < -1.25;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(f64, 0.5), found[0].literal.?.float);
    try std.testing.expectEqual(@as(f64, -1.25), found[1].literal.?.float);
}

test "a boolean literal is read" {
    const found = try read(
        \\fn check(flag: bool) void {
        \\    _ = flag == true;
        \\    _ = flag != false;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(condition.Kind.comparison, found[0].kind);
    try std.testing.expectEqual(true, found[0].literal.?.boolean);
    try std.testing.expectEqual(false, found[1].literal.?.boolean);
}

test "std.mem.eql against a string literal reads as string_equals with escapes resolved" {
    const found = try read(
        \\const std = @import("std");
        \\fn check(name: []const u8) bool {
        \\    return std.mem.eql(u8, name, "a\tb");
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(condition.Kind.string_equals, found[0].kind);
    try std.testing.expectEqualStrings("a\tb", found[0].literal.?.string);
    try std.testing.expectEqualStrings("name", found[0].subject);
    try std.testing.expectEqual(@as(u32, 3), found[0].line);
}

test "startsWith and endsWith are read and the literal may be the first string" {
    const found = try read(
        \\const std = @import("std");
        \\fn check(name: []const u8) bool {
        \\    if (std.mem.startsWith(u8, name, "pre")) {
        \\        return true;
        \\    }
        \\    return std.mem.endsWith(u8, "post", name);
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(condition.Kind.string_starts_with, found[0].kind);
    try std.testing.expectEqualStrings("pre", found[0].literal.?.string);
    try std.testing.expectEqual(condition.Kind.string_ends_with, found[1].kind);
    try std.testing.expectEqualStrings("post", found[1].literal.?.string);
    try std.testing.expectEqualStrings("name", found[1].subject);
}

test "mem.eql reached through a mem alias is read and a call with no string literal is not" {
    const found = try read(
        \\const mem = @import("std").mem;
        \\fn check(a: []const u8, b: []const u8) bool {
        \\    _ = mem.eql(u8, a, b);
        \\    return mem.eql(u8, a, "x");
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("x", found[0].literal.?.string);
}

test "a string comparison against something that is not std.mem is not read" {
    const found = try read(
        \\fn check(a: []const u8) bool {
        \\    return other.eql(u8, a, "x");
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "switch prongs report each value, a range's start and an else prong" {
    const found = try read(
        \\fn check(x: u8) u8 {
        \\    return switch (x) {
        \\        1, 2 => 10,
        \\        5...9 => 20,
        \\        else => 30,
        \\    };
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 4), found.len);
    for (found) |item| {
        try std.testing.expectEqual(condition.Kind.switch_prong, item.kind);
        try std.testing.expectEqualStrings("x", item.subject);
    }
    try std.testing.expectEqual(@as(i128, 1), found[0].literal.?.int);
    try std.testing.expectEqual(@as(u32, 3), found[0].line);
    try std.testing.expectEqual(@as(i128, 2), found[1].literal.?.int);
    try std.testing.expectEqual(@as(i128, 5), found[2].literal.?.int);
    try std.testing.expectEqual(@as(u32, 4), found[2].line);
    try std.testing.expect(found[3].literal == null);
    try std.testing.expectEqual(@as(u32, 5), found[3].line);
}

test "switch prongs on enum tags read the tag name" {
    const found = try read(
        \\const Color = enum { red, green };
        \\fn check(c: Color) u8 {
        \\    switch (c) {
        \\        .red => return 1,
        \\        Color.green => return 2,
        \\    }
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("red", found[0].literal.?.enum_tag);
    try std.testing.expectEqualStrings("green", found[1].literal.?.enum_tag);
}

test "an enum tag comparison reads the tag" {
    const found = try read(
        \\const Color = enum { red, green };
        \\fn check(c: Color) bool {
        \\    _ = c == Color.green;
        \\    return c == .red;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(condition.Kind.comparison, found[0].kind);
    try std.testing.expectEqualStrings("green", found[0].literal.?.enum_tag);
    try std.testing.expectEqualStrings("red", found[1].literal.?.enum_tag);
    try std.testing.expectEqualStrings("c", found[1].subject);
}

test "a field access on a lower case name is not an enum tag" {
    const found = try read(
        \\fn check(x: u32, limits: Limits) bool {
        \\    return x == limits.max;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "comparison with null is an optional check, from either side" {
    const found = try read(
        \\fn check(x: ?u8) bool {
        \\    _ = null == x;
        \\    return x != null;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    for (found) |item| {
        try std.testing.expectEqual(condition.Kind.optional_check, item.kind);
        try std.testing.expect(item.literal.? == .null_value);
        try std.testing.expectEqualStrings("x", item.subject);
    }
    try std.testing.expectEqual(condition.Operator.equal, found[0].operator.?);
    try std.testing.expectEqual(condition.Operator.not_equal, found[1].operator.?);
}

test "orelse and if with a payload are optional checks" {
    const found = try read(
        \\fn check(x: ?u8, y: ?u8) u8 {
        \\    const a = x orelse 0;
        \\    if (y) |value| {
        \\        return value + a;
        \\    }
        \\    return a;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(condition.Kind.optional_check, found[0].kind);
    try std.testing.expectEqualStrings("x", found[0].subject);
    try std.testing.expectEqual(@as(u32, 2), found[0].line);
    try std.testing.expectEqual(condition.Kind.optional_check, found[1].kind);
    try std.testing.expectEqualStrings("y", found[1].subject);
    try std.testing.expectEqual(@as(u32, 3), found[1].line);
}

test "while with a payload is an optional check" {
    const found = try read(
        \\fn check(it: *Iterator) void {
        \\    while (it.next()) |item| {
        \\        _ = item;
        \\    }
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(condition.Kind.optional_check, found[0].kind);
    try std.testing.expectEqualStrings("it.next()", found[0].subject);
}

test "catch, an else with an error payload and a comparison with an error value are error checks" {
    const found = try read(
        \\fn check(a: anyerror!u8, b: anyerror!u8, e: anyerror) u8 {
        \\    const x = a catch 0;
        \\    if (b) |value| {
        \\        _ = value;
        \\    } else |err| {
        \\        _ = err;
        \\    }
        \\    _ = e == error.Missing;
        \\    return x;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqual(condition.Kind.error_check, found[0].kind);
    try std.testing.expectEqualStrings("a", found[0].subject);
    try std.testing.expectEqual(condition.Kind.error_check, found[1].kind);
    try std.testing.expectEqualStrings("b", found[1].subject);
    try std.testing.expectEqual(condition.Kind.error_check, found[2].kind);
    try std.testing.expectEqualStrings("e", found[2].subject);
    try std.testing.expectEqual(condition.Operator.equal, found[2].operator.?);
}

test "try is not a condition" {
    const found = try read(
        \\fn check(a: anyerror!u8) !u8 {
        \\    return try a;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "conditions come back in line order and nested functions are left out" {
    const found = try read(
        \\fn check(x: u32) u32 {
        \\    const inner = struct {
        \\        fn deeper(y: u32) bool {
        \\            return y == 99;
        \\        }
        \\    };
        \\    _ = inner;
        \\    if (x == 3) {
        \\        return 1;
        \\    }
        \\    return x + 1;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(i128, 3), found[0].literal.?.int);
    try std.testing.expectEqual(@as(u32, 8), found[0].line);
}

test "only the named function's conditions are read" {
    const source =
        \\fn one(x: u32) bool {
        \\    return x == 1;
        \\}
        \\fn two(x: u32) bool {
        \\    return x == 2;
        \\}
    ;
    const found = try read(source, "two");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(i128, 2), found[0].literal.?.int);
    try std.testing.expectEqual(@as(u32, 5), found[0].line);
}

test "a function named in two places has both read" {
    const found = try read(
        \\const A = struct {
        \\    fn run(x: u32) bool {
        \\        return x == 1;
        \\    }
        \\};
        \\const B = struct {
        \\    fn run(x: u32) bool {
        \\        return x == 2;
        \\    }
        \\};
    , "run");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqual(@as(i128, 1), found[0].literal.?.int);
    try std.testing.expectEqual(@as(i128, 2), found[1].literal.?.int);
}

test "a literal in a string or comment is not a condition" {
    const found = try read(
        \\fn check(x: u32) bool {
        \\    // x == 5
        \\    const text = "x == 6";
        \\    _ = text;
        \\    return x > 7;
        \\}
    , "check");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(i128, 7), found[0].literal.?.int);
}

test "an unknown function is an error" {
    try std.testing.expectError(error.FunctionNotFound, read("fn one() void {}", "two"));
}

test "source that does not parse is an error" {
    try std.testing.expectError(error.SourceDoesNotParse, read("fn one( {", "one"));
}

test "a function with no conditions gives an empty list" {
    const found = try read("fn one() u32 {\n    return 1;\n}\n", "one");
    defer conditions.freeConditions(std.testing.allocator, found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "memory is released when the reader runs out of it part way" {
    const source =
        \\const std = @import("std");
        \\fn check(name: []const u8, x: u32) bool {
        \\    if (std.mem.eql(u8, name, "a")) {
        \\        return x == 1;
        \\    }
        \\    return std.mem.startsWith(u8, name, "b");
        \\}
    ;
    var index: usize = 0;
    while (index < 40) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
        const result = conditions.conditionsIn(failing.allocator(), source, "check");
        if (result) |found| {
            conditions.freeConditions(failing.allocator(), found);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}
