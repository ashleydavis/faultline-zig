const std = @import("std");
const make_public = @import("make_public.zig");

fn expectMadePublic(source: [:0]const u8, expected: []const u8) !void {
    const made = try make_public.makePublic(std.testing.allocator, source);
    defer std.testing.allocator.free(made);
    try std.testing.expectEqualStrings(expected, made);
}

test "makePublic puts pub in front of a private function and leaves a public one as it is" {
    try expectMadePublic(
        "fn double(x: u32) u32 {\n    return x * 2;\n}\npub fn run() void {}\n",
        "pub fn double(x: u32) u32 {\n    return x * 2;\n}\npub fn run() void {}\n",
    );
}

test "makePublic puts pub in front of the modifiers of a function" {
    try expectMadePublic(
        "inline fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n",
        "pub inline fn add(a: u32, b: u32) u32 {\n    return a + b;\n}\n",
    );
}

test "makePublic makes a private struct and its private methods public at every depth" {
    try expectMadePublic(
        "const Box = struct {\n    n: u32,\n    fn get(self: Box) u32 {\n        return self.n;\n    }\n    const Inner = struct {\n        fn zero() u32 {\n            return 0;\n        }\n    };\n};\n",
        "pub const Box = struct {\n    n: u32,\n    pub fn get(self: Box) u32 {\n        return self.n;\n    }\n    pub const Inner = struct {\n        pub fn zero() u32 {\n            return 0;\n        }\n    };\n};\n",
    );
}

test "makePublic makes the private methods of a public enum and union public" {
    try expectMadePublic(
        "pub const Colour = enum {\n    red,\n    fn isRed(self: Colour) bool {\n        return self == .red;\n    }\n};\npub const Shape = union(enum) {\n    dot: void,\n    fn isDot(self: Shape) bool {\n        return self == .dot;\n    }\n};\n",
        "pub const Colour = enum {\n    red,\n    pub fn isRed(self: Colour) bool {\n        return self == .red;\n    }\n};\npub const Shape = union(enum) {\n    dot: void,\n    pub fn isDot(self: Shape) bool {\n        return self == .dot;\n    }\n};\n",
    );
}

test "makePublic leaves imports, values, variables and functions without a body as they are" {
    const source =
        \\const std = @import("std");
        \\const limit: u32 = 9;
        \\var count: u32 = 0;
        \\extern fn write(fd: i32) isize;
        \\
    ;
    try expectMadePublic(source, source);
}

test "makePublic keeps every line on the number it had" {
    const made = try make_public.makePublic(std.testing.allocator, "const A = struct {\n    fn a() void {}\n};\nfn b() void {}\n");
    defer std.testing.allocator.free(made);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, made, "\n"));
}

test "makePublic returns a source that does not parse as it is" {
    try expectMadePublic("fn broken( {\n", "fn broken( {\n");
}
