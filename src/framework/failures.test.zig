const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");

// The heading in docs/FAILURES.md for each effect, in the order of `point.Effect`.
const headings = [_]struct { effect: point.Effect, heading: []const u8 }{
    .{ .effect = .allocator, .heading = "Allocator" },
    .{ .effect = .file_open, .heading = "File open, create and check" },
    .{ .effect = .read, .heading = "Read" },
    .{ .effect = .write, .heading = "Write" },
    .{ .effect = .link, .heading = "Symlink and link operations" },
    .{ .effect = .directory_listing, .heading = "Directory listing" },
    .{ .effect = .network, .heading = "Network" },
    .{ .effect = .clock, .heading = "Clock" },
    .{ .effect = .writer, .heading = "Writer" },
    .{ .effect = .delete, .heading = "Delete" },
    .{ .effect = .make_directory, .heading = "Create a directory" },
    .{ .effect = .resolve_path, .heading = "Resolve a path" },
    .{ .effect = .standard_stream, .heading = "Standard input, output and error" },
    .{ .effect = .spawn, .heading = "Running another program" },
    .{ .effect = .environment, .heading = "Environment variables" },
    .{ .effect = .thread, .heading = "Threads" },
    .{ .effect = .cancellation, .heading = "Cancellation" },
    .{ .effect = .rename_copy, .heading = "Rename and copy" },
    .{ .effect = .attributes, .heading = "Change permissions, owner or timestamps" },
    .{ .effect = .file_state, .heading = "File length, sync and locks" },
    .{ .effect = .random, .heading = "Secure random numbers" },
    .{ .effect = .current_directory, .heading = "Current directory" },
};

// The rows under a heading in the failures table, as the "Failure" cell.
fn rowsUnder(allocator: std.mem.Allocator, document: []const u8, heading: []const u8) !std.ArrayList([]const u8) {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer rows.deinit(allocator);

    var inside = false;
    var lines = std.mem.splitScalar(u8, document, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) {
            inside = std.mem.eql(u8, line[3..], heading);
            continue;
        }
        if (!inside or !std.mem.startsWith(u8, line, "| ")) {
            continue;
        }
        if (std.mem.startsWith(u8, line, "| Failure |") or std.mem.startsWith(u8, line, "| ---")) {
            continue;
        }
        const rest = line[2..];
        const end = std.mem.indexOf(u8, rest, " | ") orelse continue;
        try rows.append(allocator, rest[0..end]);
    }
    return rows;
}

test "every effect has a heading in the failures table" {
    try std.testing.expectEqual(point.effect_count, headings.len);
    inline for (headings, 0..) |entry, index| {
        try std.testing.expectEqual(index, @intFromEnum(entry.effect));
    }
}

test "the failures declared for each effect match the rows of docs/FAILURES.md" {
    const document = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/FAILURES.md", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(document);

    inline for (headings) |entry| {
        var rows = try rowsUnder(std.testing.allocator, document, entry.heading);
        defer rows.deinit(std.testing.allocator);

        const kinds = failures.kindsOf(entry.effect);
        try std.testing.expectEqual(rows.items.len, kinds.len);
        for (rows.items, kinds) |row, kind| {
            try std.testing.expectEqualStrings(row, kind.description);
        }
    }
}

test "failure ids are unique within an effect" {
    inline for (headings) |entry| {
        const kinds = failures.kindsOf(entry.effect);
        for (kinds, 0..) |kind, index| {
            for (kinds[index + 1 ..]) |other| {
                try std.testing.expect(!std.mem.eql(u8, kind.id, other.id));
            }
        }
    }
}

test "every failure has an id and a description" {
    inline for (headings) |entry| {
        for (failures.kindsOf(entry.effect)) |kind| {
            try std.testing.expect(kind.id.len > 0);
            try std.testing.expect(kind.description.len > 0);
        }
    }
}
