// The results of earlier runs, kept in the build's cache, so a run does not execute again code that
// an earlier run already proved and that has not changed since. What is kept is the complete result
// of one file: every call's tally, every failure and which code paths ended the run exercised. A
// run that loads a file's result reports it exactly as the run that made it did.
//
// A result is kept per file a run hands to a worker: a source file, whose functions are called, or
// a sim file, whose scenarios are run. Each is stored with a key, a hash of the file and of
// everything it imports, at any depth, and of Faultline itself. A source file's key covers its own
// sim file and every `global.sim.zig` too, because their value factories and expectation functions
// decide its calls. A change to any of those gives a different key, and the result is not used.
//
// A code path of one file can be exercised by the calls of another: a private helper by the
// functions of the file that calls it, or anything by a scenario. So each result also names the
// files whose calls exercised its code paths, with their keys. The result is used only while
// every one of them still has the key it had, and when a file is run again, so is every file that
// exercised its code paths, so the file gets what they exercised in it again.

const std = @import("std");
const module_table = @import("../cmd/module_table.zig");
const wire = @import("wire.zig");
const worker = @import("worker.zig");

// What the first line of a stored result says. A result written by any other version of this
// format is thrown away, so a change to the format never misreads an older result.
pub const format_version: u32 = 1;

// The word the first line starts with, so a file that is not a stored result is not read as one.
const format_word = "faultline-results";

// A file whose calls exercised code paths of the file a result is of, and its key at the time.
pub const Contributor = struct {
    // The file, relative to the project root.
    file: []const u8,

    // Its key when the result was made.
    key: u64,
};

// Which code paths of one function the run ended with exercised.
pub const Marks = struct {
    // The function, as its checklist names it.
    function: []const u8,

    // One character per code path, in the checklist's order: `t` for exercised, `m` for one whose
    // line the build had no code for, `.` for neither.
    marks: []const u8,
};

// The complete result of one file.
pub const Entry = struct {
    // The file, relative to the project root.
    file: []const u8,

    // Its key when the result was made.
    key: u64,

    // Every file whose calls exercised one of its code paths, itself included.
    contributors: []const Contributor = &.{},

    // Its functions' code paths, one per checklist of the file, in the order they were built.
    marks: []const Marks = &.{},

    // Its functions' tallies. The index is counted from the file's first function in the table.
    tallies: []const worker.Tally = &.{},

    // Its failures. The index is counted from the file's first function or scenario in the table.
    failures: []const worker.Failure = &.{},
};

// Writes `entry` in the format `readEntry` reads.
pub fn writeEntry(writer: *std.Io.Writer, entry: Entry) !void {
    try writer.print("{s} {d}\n", .{ format_word, format_version });
    try writer.writeAll("file\t");
    try wire.writeField(writer, entry.file);
    try writer.print("\nkey\t{x}\n", .{entry.key});
    for (entry.contributors) |contributor| {
        try writer.print("contributor\t{x}\t", .{contributor.key});
        try wire.writeField(writer, contributor.file);
        try writer.writeByte('\n');
    }
    for (entry.marks) |marks| {
        try writer.print("marks\t{s}\t", .{marks.marks});
        try wire.writeField(writer, marks.function);
        try writer.writeByte('\n');
    }
    try worker.writeFindings(writer, entry.tallies, entry.failures);
}

// Reads what `writeEntry` wrote, with everything in it allocated from `room`. Null for text that
// is not a stored result of this format version.
pub fn readEntry(room: std.mem.Allocator, text: []const u8) !?Entry {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse return null;
    var header = std.mem.splitScalar(u8, first, ' ');
    if (!std.mem.eql(u8, header.next() orelse return null, format_word)) {
        return null;
    }
    const version = std.fmt.parseInt(u32, header.next() orelse return null, 10) catch return null;
    if (version != format_version) {
        return null;
    }

    var file: ?[]const u8 = null;
    var key: ?u64 = null;
    var contributors: std.ArrayList(Contributor) = .empty;
    var marks: std.ArrayList(Marks) = .empty;
    var rest: std.Io.Writer.Allocating = .init(room);
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const tag = fields.next() orelse continue;
        if (std.mem.eql(u8, tag, "file")) {
            file = try wire.unescape(room, fields.next() orelse return null);
        } else if (std.mem.eql(u8, tag, "key")) {
            key = std.fmt.parseInt(u64, fields.next() orelse return null, 16) catch return null;
        } else if (std.mem.eql(u8, tag, "contributor")) {
            const contributor_key = std.fmt.parseInt(u64, fields.next() orelse return null, 16) catch return null;
            const contributor_file = try wire.unescape(room, fields.next() orelse return null);
            try contributors.append(room, .{ .file = contributor_file, .key = contributor_key });
        } else if (std.mem.eql(u8, tag, "marks")) {
            const written = try room.dupe(u8, fields.next() orelse return null);
            const function = try wire.unescape(room, fields.next() orelse return null);
            try marks.append(room, .{ .function = function, .marks = written });
        } else {
            try rest.writer.writeAll(line);
            try rest.writer.writeByte('\n');
        }
    }
    // `readResults` keeps what it read in an arena of its own built on `room`, so it lives as long
    // as `room` does and is never freed on its own.
    const results = try worker.readResults(room, rest.written());
    return .{
        .file = file orelse return null,
        .key = key orelse return null,
        .contributors = contributors.items,
        .marks = marks.items,
        .tallies = results.tallies,
        .failures = results.failures,
    };
}

// Where the result of `file` is kept under `directory`: a name made from a hash of the path, so a
// path's separators never have to be written into a file name. The entry itself names its file,
// and one that names another is not used.
pub fn entryPath(allocator: std.mem.Allocator, directory: []const u8, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{x:0>16}.txt", .{ directory, std.hash.Wyhash.hash(0, file) });
}

// One `@import` or `@embedFile` in a source file.
pub const Import = struct {
    // Which builtin it is.
    builtin: enum { import, embed },

    // What it names: a path, or for `@import` a module name.
    target: []const u8,
};

// Every `@import` and `@embedFile` in `source` whose argument is a string literal, in the order
// they are written. Read from the tokens, so it needs no parse of the whole file. The targets are
// allocated from `allocator`.
pub fn importsOf(allocator: std.mem.Allocator, source: [:0]const u8) ![]Import {
    var found: std.ArrayList(Import) = .empty;
    var tokenizer = std.zig.Tokenizer.init(source);
    var before_last: std.zig.Token = .{ .tag = .eof, .loc = .{ .start = 0, .end = 0 } };
    var last: std.zig.Token = before_last;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) {
            break;
        }
        if (token.tag == .string_literal and last.tag == .l_paren and before_last.tag == .builtin) {
            const name = source[before_last.loc.start..before_last.loc.end];
            const builtin: ?@FieldType(Import, "builtin") = if (std.mem.eql(u8, name, "@import"))
                .import
            else if (std.mem.eql(u8, name, "@embedFile"))
                .embed
            else
                null;
            if (builtin) |kind| {
                const target = std.zig.string_literal.parseAlloc(allocator, source[token.loc.start..token.loc.end]) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => null,
                };
                if (target) |text| {
                    try found.append(allocator, .{ .builtin = kind, .target = text });
                }
            }
        }
        before_last = last;
        last = token;
    }
    return found.toOwnedSlice(allocator);
}

// What a key is made from besides the files themselves.
pub const KeyInputs = struct {
    // The directory the project's files were copied to.
    sources_root: []const u8,

    // The project's own directory, for a file `@embedFile` names, which is not copied.
    repository: []const u8,

    // The modules of the project's build.
    modules: []const module_table.Module,

    // Faultline itself and how the program was built, so a new Faultline throws every result
    // away.
    salt: []const u8,
};

// The key of the files `roots` and of everything they import, at any depth, or null when one of
// them imports a module the build generates, whose content the program cannot read. Every root is
// relative to the project root.
pub fn keyOf(allocator: std.mem.Allocator, io: std.Io, inputs: KeyInputs, roots: []const []const u8) !?u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const room = arena.allocator();

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(inputs.salt);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    for (roots) |root| {
        if (!seen.contains(root)) {
            try seen.put(room, root, {});
            try queue.append(room, root);
        }
    }

    var sources = std.Io.Dir.cwd().openDir(io, inputs.sources_root, .{}) catch return null;
    defer sources.close(io);

    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const path = queue.items[next];
        hasher.update(path);
        hasher.update("\x00");
        const source = sources.readFileAllocOptions(io, path, room, .unlimited, .of(u8), 0) catch {
            hasher.update("missing\x00");
            continue;
        };
        hasher.update(source);
        hasher.update("\x00");

        for (try importsOf(room, source)) |import| {
            switch (import.builtin) {
                .embed => {
                    const resolved = try resolveBeside(room, path, import.target);
                    hasher.update(resolved);
                    hasher.update("\x00");
                    hashFileOf(io, &hasher, inputs.repository, resolved, room);
                },
                .import => {
                    if (std.mem.endsWith(u8, import.target, ".zig")) {
                        const resolved = try resolveBeside(room, path, import.target);
                        if (!seen.contains(resolved)) {
                            try seen.put(room, resolved, {});
                            try queue.append(room, resolved);
                        }
                        continue;
                    }
                    if (isBuiltInModule(import.target)) {
                        continue;
                    }
                    hasher.update(import.target);
                    hasher.update("\x00");
                    const module = moduleNamed(inputs.modules, import.target) orelse continue;
                    switch (module.place) {
                        .project => if (!seen.contains(module.path)) {
                            try seen.put(room, module.path, {});
                            try queue.append(room, module.path);
                        },
                        .outside => {
                            hasher.update(module.path);
                            hasher.update("\x00");
                            hashFileOf(io, &hasher, "", module.path, room);
                        },
                        .generated => return null,
                    }
                },
            }
        }
    }
    return hasher.final();
}

// The modules every program has, which change only with Zig or with Faultline, both of which are in
// the salt of every key.
fn isBuiltInModule(name: []const u8) bool {
    const built_in = [_][]const u8{ "std", "builtin", "root", "sim", "faultline" };
    for (built_in) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }
    return false;
}

fn moduleNamed(modules: []const module_table.Module, name: []const u8) ?module_table.Module {
    for (modules) |module| {
        if (std.mem.eql(u8, module.name, name)) {
            return module;
        }
    }
    return null;
}

// The path `target` names from a file at `from`, both relative to the project root.
fn resolveBeside(room: std.mem.Allocator, from: []const u8, target: []const u8) ![]const u8 {
    const directory = std.fs.path.dirnamePosix(from) orelse ".";
    return std.fs.path.resolvePosix(room, &.{ directory, target });
}

// Adds the contents of `path`, under `directory` when it is relative, to `hasher`, or a mark that
// it could not be read.
fn hashFileOf(io: std.Io, hasher: *std.hash.Wyhash, directory: []const u8, path: []const u8, room: std.mem.Allocator) void {
    const full = if (directory.len == 0 or std.fs.path.isAbsolute(path))
        path
    else
        std.fs.path.join(room, &.{ directory, path }) catch {
            hasher.update("unreadable\x00");
            return;
        };
    const contents = std.Io.Dir.cwd().readFileAlloc(io, full, room, .unlimited) catch {
        hasher.update("unreadable\x00");
        return;
    };
    hasher.update(contents);
    hasher.update("\x00");
}

// What a run needs to know about one file to decide whether its stored result can be used.
pub const Unit = struct {
    // The file, relative to the project root.
    file: []const u8,

    // Its key in this run, or null when it has none.
    key: ?u64,

    // Its stored result, or null when there is none of this format.
    entry: ?Entry,
};

// Which of `units` have to run again, as a slice parallel to `units`. A unit runs again when it has
// no key, no stored result, a stored result with another key, or a contributor whose key is not
// what it was. Then every contributor of a unit that runs again runs again too, until no more are
// added, so a file run again gets the code paths those files exercised in it.
pub fn unitsToRun(allocator: std.mem.Allocator, units: []const Unit) ![]bool {
    const to_run = try allocator.alloc(bool, units.len);
    for (units, to_run) |unit, *runs| {
        runs.* = !isUsable(units, unit);
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (units, to_run) |unit, runs| {
            if (!runs) {
                continue;
            }
            const entry = unit.entry orelse continue;
            for (entry.contributors) |contributor| {
                const position = positionOf(units, contributor.file) orelse continue;
                if (!to_run[position]) {
                    to_run[position] = true;
                    changed = true;
                }
            }
        }
    }
    return to_run;
}

// Whether a unit's stored result can be used as it is.
fn isUsable(units: []const Unit, unit: Unit) bool {
    const key = unit.key orelse return false;
    const entry = unit.entry orelse return false;
    if (entry.key != key or !std.mem.eql(u8, entry.file, unit.file)) {
        return false;
    }
    for (entry.contributors) |contributor| {
        const position = positionOf(units, contributor.file) orelse return false;
        const now = units[position].key orelse return false;
        if (now != contributor.key) {
            return false;
        }
    }
    return true;
}

fn positionOf(units: []const Unit, file: []const u8) ?usize {
    for (units, 0..) |unit, position| {
        if (std.mem.eql(u8, unit.file, file)) {
            return position;
        }
    }
    return null;
}

test {
    _ = @import("results_cache.test.zig");
}
