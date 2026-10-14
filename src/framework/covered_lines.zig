// What kcov saw run, read back off the cobertura file it writes.
//
// kcov watches the simulation binary from outside and, when it exits, writes one `<class>` per
// source file and one `<line>` per line the binary has code for, with `hits` saying whether that
// line ran. This reads that file into a set per source file, so a checklist can ask whether the
// line that proves one of its paths ran, and whether the build had any code for it at all.
//
// No XML library. kcov writes the two elements this reads in one fixed form each, so they are found
// with a text search, and anything else in the file is passed over.

const std = @import("std");

// Which lines of one source file the build has code for, and which of those a run executed.
pub const LineSet = struct {
    // Every line kcov listed as having code, whether or not it ran.
    code: std.AutoHashMapUnmanaged(u32, void) = .empty,

    // The lines kcov saw run.
    hit: std.AutoHashMapUnmanaged(u32, void) = .empty,

    // Whether `line` ran.
    pub fn isHit(self: *const LineSet, line: u32) bool {
        return self.hit.contains(line);
    }

    // Whether the build had code for `line`. A line kcov never listed has no address in the
    // binary, so no run can ever hit it.
    pub fn isCode(self: *const LineSet, line: u32) bool {
        return self.code.contains(line);
    }

    pub fn deinit(self: *LineSet, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.hit.deinit(allocator);
    }
};

// Every file kcov reported, keyed by the `filename` kcov wrote, which is the file's path with the
// prefix every reported file shares taken off.
pub const CoveredLines = struct {
    // What every map here was allocated with.
    allocator: std.mem.Allocator,

    // One set per reported file. The key is owned here.
    files: std.StringHashMapUnmanaged(LineSet) = .empty,

    pub fn deinit(self: *CoveredLines) void {
        var entries = self.files.iterator();
        while (entries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.files.deinit(self.allocator);
    }

    // The lines kcov reported for `file`, a path relative to the repository the way the report
    // names files, whose copy the run was compiled from sits under `sources_root`. kcov writes a
    // reported path with the prefix every reported file shares taken off, so the match is on the
    // end of the path: the copy's full path ends with the reported name, or is the reported name.
    // Null when kcov reported no such file.
    pub fn linesFor(self: *const CoveredLines, sources_root: []const u8, file: []const u8) ?*const LineSet {
        var entries = self.files.iterator();
        while (entries.next()) |entry| {
            if (isSameFile(sources_root, file, entry.key_ptr.*)) {
                return entry.value_ptr;
            }
        }
        return null;
    }
};

// Whether `reported`, as kcov wrote it, names the copy of `file` under `sources_root`.
pub fn isSameFile(sources_root: []const u8, file: []const u8, reported: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ sources_root, file }) catch return false;
    if (std.mem.eql(u8, full, reported)) {
        return true;
    }
    if (reported.len >= full.len) {
        return false;
    }
    if (!std.mem.endsWith(u8, full, reported)) {
        return false;
    }
    return full[full.len - reported.len - 1] == '/';
}

// The two errors this module adds to running out of memory: the file kcov should have written is
// not there, or a number in it is not one.
pub const ReadError = std.mem.Allocator.Error || error{ CoverageFileMissing, CoverageFileUnreadable };

// Reads the cobertura file at `path` and parses it. `CoverageFileMissing` when there is no file
// there, which is what a kcov run that never got as far as writing one leaves behind.
pub fn readCobertura(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ReadError!CoveredLines {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.CoverageFileMissing,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CoverageFileUnreadable,
    };
    defer allocator.free(text);
    return parseCobertura(allocator, text);
}

// Reads every `<class ... filename="...">` and every `<line number="N" hits="H"/>` in `text`. A
// `<line>` belongs to the most recent `<class>`; one before any class is passed over, as is a line
// with no number. A file reported more than once has its sets merged.
pub fn parseCobertura(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!CoveredLines {
    var found: CoveredLines = .{ .allocator = allocator };
    errdefer found.deinit();

    var current: ?*LineSet = null;
    var rest = text;
    while (rest.len != 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];

        if (std.mem.indexOf(u8, line, "<class ") != null) {
            const name = attribute(line, "filename") orelse {
                current = null;
                continue;
            };
            const entry = try found.files.getOrPut(allocator, name);
            if (!entry.found_existing) {
                entry.key_ptr.* = try allocator.dupe(u8, name);
                entry.value_ptr.* = .{};
            }
            current = entry.value_ptr;
            continue;
        }

        if (std.mem.indexOf(u8, line, "<line ") != null) {
            const set = current orelse continue;
            const number_text = attribute(line, "number") orelse continue;
            const number = std.fmt.parseInt(u32, number_text, 10) catch continue;
            try set.code.put(allocator, number, {});
            const hits_text = attribute(line, "hits") orelse continue;
            const hits = std.fmt.parseInt(u32, hits_text, 10) catch continue;
            if (hits > 0) {
                try set.hit.put(allocator, number, {});
            }
        }
    }

    return found;
}

// The value of `name="..."` in one line of the file, or null when the line has no such attribute.
fn attribute(line: []const u8, name: []const u8) ?[]const u8 {
    var buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buffer, " {s}=\"", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, line, marker) orelse return null) + marker.len;
    const length = std.mem.indexOfScalar(u8, line[start..], '"') orelse return null;
    return line[start .. start + length];
}

test {
    //
    // The tests live in their own file so a change to them is never mistaken for a change to the
    // code. Nothing else imports that file, so naming it here is what runs it.
    //
    _ = @import("covered_lines.test.zig");
}
