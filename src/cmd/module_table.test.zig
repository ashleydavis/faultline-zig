const std = @import("std");
const module_table = @import("module_table.zig");

test "a module table reads back what it was rendered from" {
    const modules = [_]module_table.Module{
        .{ .name = "skilled", .place = .project, .path = "src/lib/root.zig" },
        .{ .name = "yaml", .place = .outside, .path = "/packages/yaml/src/root.zig" },
        .{ .name = "options", .place = .generated, .path = "" },
    };
    const text = try module_table.render(std.testing.allocator, &modules);
    defer std.testing.allocator.free(text);

    const read = try module_table.parse(std.testing.allocator, text);
    defer std.testing.allocator.free(read);

    try std.testing.expectEqual(modules.len, read.len);
    for (modules, read) |expected, actual| {
        try std.testing.expectEqualStrings(expected.name, actual.name);
        try std.testing.expectEqual(expected.place, actual.place);
        try std.testing.expectEqualStrings(expected.path, actual.path);
    }
}

test "a module table passes over a line it cannot read" {
    const read = try module_table.parse(std.testing.allocator, "half\n\tproject\tx.zig\nname\tnowhere\tx.zig\nok\tproject\tok.zig\n");
    defer std.testing.allocator.free(read);

    try std.testing.expectEqual(@as(usize, 1), read.len);
    try std.testing.expectEqualStrings("ok", read[0].name);
}
