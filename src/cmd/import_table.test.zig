const std = @import("std");
const import_table = @import("import_table.zig");

test "a table with no files has empty tuples" {
    const text = try import_table.render(std.testing.allocator, &.{}, &.{});
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "pub const sources = .{\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pub const simulations = .{\n};") != null);
}

test "each source file becomes a line naming its path and importing it" {
    const sources = [_]import_table.Source{ .{ .path = "src/a.zig" }, .{ .path = "b.zig" } };
    const text = try import_table.render(std.testing.allocator, &sources, &.{});
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, ".{ .path = \"src/a.zig\", .namespace = @import(\"src/a.zig\") },") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".{ .path = \"b.zig\", .namespace = @import(\"b.zig\") },") != null);
}

test "each sim file becomes a line naming its path and the source it belongs to" {
    const simulations = [_]import_table.Simulation{.{ .path = "src/a.sim.zig", .source = "src/a.zig" }};
    const text = try import_table.render(std.testing.allocator, &.{}, &simulations);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, ".{ .path = \"src/a.sim.zig\", .source = \"src/a.zig\", .namespace = @import(\"src/a.sim.zig\") },") != null);
}

test "a quote or a backslash in a path is escaped" {
    const sources = [_]import_table.Source{.{ .path = "we\"ird\\name.zig" }};
    const text = try import_table.render(std.testing.allocator, &sources, &.{});
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"we\\\"ird\\\\name.zig\"") != null);
}

test "the table says it was written by the build step" {
    const text = try import_table.render(std.testing.allocator, &.{}, &.{});
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "// Written by the Faultline build step."));
}

test "the table is Zig that parses" {
    const sources = [_]import_table.Source{.{ .path = "a.zig" }};
    const simulations = [_]import_table.Simulation{.{ .path = "a.sim.zig", .source = "a.zig" }};
    const text = try import_table.render(std.testing.allocator, &sources, &simulations);
    defer std.testing.allocator.free(text);
    const terminated = try std.testing.allocator.dupeZ(u8, text);
    defer std.testing.allocator.free(terminated);

    var tree = try std.zig.Ast.parse(std.testing.allocator, terminated, .zig);
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}
