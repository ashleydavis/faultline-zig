// Tests for the report of functions that could not be called and what stopped each.

const std = @import("std");
const uncallable = @import("uncallable.zig");

// The functions found in a snippet.
fn read(source: [:0]const u8) ![]uncallable.Uncallable {
    return uncallable.uncallableFunctionsIn(std.testing.allocator, source);
}

test "a function that reads its type parameter's declarations is reported as looking inside the type" {
    const found = try read(
        \\pub fn firstDeclaration(comptime Namespace: type) []const u8 {
        \\    return @typeInfo(Namespace).@"struct".decls[0].name;
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("firstDeclaration", found[0].name);
    try std.testing.expectEqual(uncallable.Reason.reflects_on_type, found[0].reason);
    try std.testing.expectEqual(@as(u32, 1), found[0].line);
}

test "reflection in the return type counts" {
    const found = try read(
        \\pub fn oneField(comptime Enum: type) [@typeInfo(Enum).@"enum".fields.len]u8 {
        \\    return undefined;
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(uncallable.Reason.reflects_on_type, found[0].reason);
}

test "a parameter handed to a function that looks inside the type is followed there" {
    const found = try read(
        \\pub fn firstDeclaration(comptime Namespace: type) []const u8 {
        \\    return @typeInfo(Namespace).@"struct".decls[0].name;
        \\}
        \\
        \\pub fn askAnother(comptime Namespace: type) []const u8 {
        \\    return firstDeclaration(Namespace);
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("askAnother", found[1].name);
    try std.testing.expectEqual(uncallable.Reason.reflects_on_type, found[1].reason);
    try std.testing.expectEqual(@as(u32, 5), found[1].line);
}

test "a builtin that works whatever the type is does not stop a call" {
    const found = try read(
        \\pub fn howBig(comptime T: type) usize {
        \\    return @sizeOf(T);
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a function that only names its type as a return type can be called" {
    const found = try read(
        \\pub fn make(comptime T: type) ?T {
        \\    return null;
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "another parameter written in terms of the type parameter is reported as using the type" {
    const found = try read(
        \\pub fn largest(log: anytype, comptime T: type, values: []const T) ?T {
        \\    _ = log;
        \\    _ = values;
        \\    return null;
        \\}
        \\
        \\pub fn passItOn(comptime ReturnT: type, value: ReturnT) ReturnT {
        \\    return value;
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("largest", found[0].name);
    try std.testing.expectEqual(uncallable.Reason.parameter_uses_type, found[0].reason);
    try std.testing.expectEqualStrings("passItOn", found[1].name);
    try std.testing.expectEqual(uncallable.Reason.parameter_uses_type, found[1].reason);
    try std.testing.expectEqual(@as(u32, 7), found[1].line);
}

test "a type and an anytype beside it is a signature the call can make" {
    const found = try read(
        \\pub fn withRetries(log: anytype, comptime T: type, operation: anytype, attempts: usize) ?T {
        \\    _ = log;
        \\    _ = operation;
        \\    _ = attempts;
        \\    return null;
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a function with no type parameter is never reported" {
    const found = try read("pub fn add(first: usize, second: usize) usize {\n    return first + second;\n}\n");
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "a function that both looks inside the type and uses it is reported once, for looking inside" {
    const found = try read(
        \\pub fn both(comptime T: type, value: T) usize {
        \\    return @typeInfo(T).@"struct".fields.len;
        \\}
    );
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(uncallable.Reason.reflects_on_type, found[0].reason);
}

test "a function type with no name is not a function to report" {
    const found = try read("const Callback = fn (comptime T: type, value: T) void;\n");
    defer std.testing.allocator.free(found);

    try std.testing.expectEqual(@as(usize, 0), found.len);
}

test "every reason has a sentence that starts with a capital letter and ends with a full stop" {
    inline for (@typeInfo(uncallable.Reason).@"enum".fields) |field| {
        const reason: uncallable.Reason = @enumFromInt(field.value);
        const sentence = reason.sentence();
        try std.testing.expect(std.ascii.isUpper(sentence[0]));
        try std.testing.expectEqual(@as(u8, '.'), sentence[sentence.len - 1]);
    }
}
