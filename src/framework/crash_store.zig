// The crashes earlier runs found, kept so that no run loses one.
//
// Each line of the file is the replay token of a call that crashed. Every run replays every token
// before it makes calls of its own, whatever its seed, and adds the token of every crash it finds.
// A token stays after its crash is fixed, so the crash is found again if it comes back. The file is
// in the build's cache, apart from the kept results, so `--no-cache` and `zig build flt clear` leave
// it alone.

const std = @import("std");

// The tokens in the file at `path`, in the order they were added. A missing file holds none.
pub fn read(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    return tokensOf(allocator, text);
}

// The tokens in `text`, one per line that is not blank, with the spaces around each taken off.
pub fn tokensOf(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const token = std.mem.trim(u8, line, " \t\r");
        if (token.len == 0) {
            continue;
        }
        try tokens.append(allocator, token);
    }
    return tokens.toOwnedSlice(allocator);
}

// `kept` followed by every token in `found` that names a call none of them already names, in the
// order found. A crash a run finds again with a new seed is not added a second time.
pub fn withNew(allocator: std.mem.Allocator, kept: []const []const u8, found: []const []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    try tokens.appendSlice(allocator, kept);
    for (found) |token| {
        if (isAmong(tokens.items, token)) {
            continue;
        }
        try tokens.append(allocator, token);
    }
    return tokens.toOwnedSlice(allocator);
}

// Whether one of `tokens` names the same call as `token`.
pub fn isAmong(tokens: []const []const u8, token: []const u8) bool {
    for (tokens) |other| {
        if (isSameCall(other, token)) {
            return true;
        }
    }
    return false;
}

// Whether two tokens name the same call. The seed is left out of the comparison unless a value was
// drawn from it (written with `s` in `values=`), because then the seed is what decides that value.
// A crash found again under another seed with the same values and failures is taken as the one
// already kept, and the kept token goes on reproducing it with its own seed.
pub fn isSameCall(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) {
        return true;
    }
    if (hasSeededValue(left) or hasSeededValue(right)) {
        return false;
    }
    var left_parts = std.mem.splitScalar(u8, left, ';');
    var right_parts = std.mem.splitScalar(u8, right, ';');
    while (true) {
        const left_part = nextWithoutSeed(&left_parts);
        const right_part = nextWithoutSeed(&right_parts);
        if (left_part == null or right_part == null) {
            return left_part == null and right_part == null;
        }
        if (!std.mem.eql(u8, left_part.?, right_part.?)) {
            return false;
        }
    }
}

// Whether `token` holds a value drawn from its seed.
fn hasSeededValue(token: []const u8) bool {
    var parts = std.mem.splitScalar(u8, token, ';');
    while (parts.next()) |part| {
        if (!std.mem.startsWith(u8, part, "values=")) {
            continue;
        }
        var values = std.mem.splitScalar(u8, part["values=".len..], ',');
        while (values.next()) |one| {
            if (std.mem.startsWith(u8, one, "s")) {
                return true;
            }
        }
    }
    return false;
}

// The next part of a token after any `seed=` part.
fn nextWithoutSeed(parts: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (parts.next()) |part| {
        if (!std.mem.startsWith(u8, part, "seed=")) {
            return part;
        }
    }
    return null;
}

// Writes `tokens` to the file at `path`, one per line, creating the directory it is in.
pub fn write(allocator: std.mem.Allocator, io: std.Io, path: []const u8, tokens: []const []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io, directory);
    }
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    for (tokens) |token| {
        try text.writer.print("{s}\n", .{token});
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = text.written(),
    });
}

test {
    _ = @import("crash_store.test.zig");
}
