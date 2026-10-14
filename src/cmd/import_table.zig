// The one file the build step writes for the program it builds: a table of the project's files.
//
// Zig accepts an `@import` path only as a string literal in source, so the program cannot be given
// a list of files as data and import them from it. The build step writes this table into the
// build's cache instead. It holds data and no logic: one line per file, naming its path and the
// namespace the file declares. Everything that decides what to do with a file is in Faultline's own
// source.

const std = @import("std");

// A source file to fault test.
pub const Source = struct {
    // The path relative to the project root, with `/` separators.
    path: []const u8,
};

// A sim file and the source file it belongs to.
pub const Simulation = struct {
    // The path of the sim file relative to the project root.
    path: []const u8,

    // The path of the source file beside it, whether or not that file is in the table.
    source: []const u8,
};

// What the table starts with, so a reader who opens it in the cache knows what it is.
const header =
    \\// Written by the Faultline build step. It lists the files of the project so the program can reach
    \\// them: Zig reads an import path only from a string literal in source. It holds data and no logic.
    \\
;

// Renders the table. The caller owns the text.
pub fn render(allocator: std.mem.Allocator, sources: []const Source, simulations: []const Simulation) ![]u8 {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    const writer = &text.writer;

    try writer.writeAll(header);
    try writer.writeAll("\npub const sources = .{\n");
    for (sources) |source| {
        try writer.writeAll("    .{ .path = ");
        try writeLiteral(writer, source.path);
        try writer.writeAll(", .namespace = @import(");
        try writeLiteral(writer, source.path);
        try writer.writeAll(") },\n");
    }
    try writer.writeAll("};\n\npub const simulations = .{\n");
    for (simulations) |simulation| {
        try writer.writeAll("    .{ .path = ");
        try writeLiteral(writer, simulation.path);
        try writer.writeAll(", .source = ");
        try writeLiteral(writer, simulation.source);
        try writer.writeAll(", .namespace = @import(");
        try writeLiteral(writer, simulation.path);
        try writer.writeAll(") },\n");
    }
    try writer.writeAll("};\n");
    return text.toOwnedSlice();
}

// Writes a string literal, escaping what a literal cannot hold as it is.
fn writeLiteral(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test {
    _ = @import("import_table.test.zig");
}
