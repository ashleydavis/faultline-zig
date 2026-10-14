// The table of the modules a project's build has, which the build step writes beside the copy of
// the project's files. The program reads it to follow an import of a module by name to the file
// it is rooted in, so the results it keeps of an earlier run are thrown away when that file or
// anything it imports changes. It holds data and no logic: one line per module.

const std = @import("std");

// Where a module's root file is.
pub const Place = enum {
    // In the project, so its copy is beside the copies of the project's files. `path` is relative
    // to the project root.
    project,

    // Outside the project, such as in a package Zig fetched. `path` is absolute.
    outside,

    // Written by a step of the build, so it can change without any file the program can read
    // changing. `path` is empty.
    generated,
};

// One module of the build.
pub const Module = struct {
    // The name the project imports it by.
    name: []const u8,

    // Where its root file is.
    place: Place,

    // The path of its root file, read as `place` says.
    path: []const u8,
};

// Renders the table. The caller owns the text.
pub fn render(allocator: std.mem.Allocator, modules: []const Module) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    for (modules) |module| {
        try text.writer.print("{s}\t{t}\t{s}\n", .{ module.name, module.place, module.path });
    }
    return text.toOwnedSlice();
}

// Reads what `render` wrote. A line that does not parse is passed over. The names and paths are
// slices of `text`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]Module {
    var modules: std.ArrayList(Module) = .empty;
    errdefer modules.deinit(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse continue;
        const place = std.meta.stringToEnum(Place, fields.next() orelse continue) orelse continue;
        const path = fields.next() orelse continue;
        if (name.len == 0) {
            continue;
        }
        try modules.append(allocator, .{ .name = name, .place = place, .path = path });
    }
    return modules.toOwnedSlice(allocator);
}

// The name of the file the table is written to, beside the copies of the project's files.
pub const file_name = "flt_modules.txt";

test {
    _ = @import("module_table.test.zig");
}
