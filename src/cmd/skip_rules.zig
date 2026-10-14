// The rules that decide whether the walk takes a file or directory and the reason it gives when it
// does not. Kept apart from the walk so each rule can be tested by itself and the walk only has to
// decide in what order to ask.

const std = @import("std");

// The name the framework's module is imported under. A source file that imports it is a harness and
// not code to be fault tested.
pub const framework_module = "\"sim\"";

// Why the walk took or skipped one file or directory.
pub const Reason = enum {
    // A file that is code to fault test.
    taken_source,

    // A file that holds value factories, scenarios or expectation functions.
    taken_sim,

    // A directory the walk went into.
    searched_directory,

    // A directory whose name starts with a dot.
    dot_directory,

    // A directory whose name is listed in `.gitignore`.
    ignored_directory,

    // A directory that is the root of a linked git worktree.
    worktree_root,

    // A file that is a unit test.
    test_file,

    // A file that is a sim file's own unit test.
    sim_test_file,

    // The build script.
    build_script,

    // The build manifest.
    build_manifest,

    // A file named as a fuzz entry point.
    fuzz_file,

    // A file that is not named like Zig source.
    not_zig_file,

    // A file that imports the framework but is not a sim file.
    imports_framework,

    // A file that is not valid Zig, or whose top level holds more than declarations.
    does_not_parse,

    // A file that could not be read.
    unreadable,

    // A path the exclude option names, or lies below one it names.
    excluded,

    // A path the include option names that is not in the project.
    not_found,

    // Whether the walk took the path.
    pub fn isTaken(reason: Reason) bool {
        return switch (reason) {
            .taken_source, .taken_sim, .searched_directory => true,
            else => false,
        };
    }

    // A sentence saying why, for the report.
    pub fn sentence(reason: Reason) []const u8 {
        return switch (reason) {
            .taken_source => "Taken as code to fault test.",
            .taken_sim => "Taken as a sim file holding value factories, scenarios and expectation functions.",
            .searched_directory => "Searched for Zig files.",
            .dot_directory => "Skipped because the directory name starts with a dot.",
            .ignored_directory => "Skipped because the directory name is listed in .gitignore.",
            .worktree_root => "Skipped because the directory is the root of a linked git worktree.",
            .test_file => "Skipped because the file is a unit test.",
            .sim_test_file => "Skipped because the file is the unit test of a sim file.",
            .build_script => "Skipped because the file is a build script.",
            .build_manifest => "Skipped because the file is a build manifest.",
            .fuzz_file => "Skipped because the file name starts with fuzz_, which marks a fuzz entry point.",
            .not_zig_file => "Skipped because the file name does not end in .zig.",
            .imports_framework => "Skipped because the file imports the framework and is not named as a sim file.",
            .does_not_parse => "Skipped because the file is not valid Zig source.",
            .unreadable => "Skipped because the file could not be read.",
            .excluded => "Skipped because the exclude option names it or a directory above it.",
            .not_found => "Skipped because the include option names a path that is not in the project.",
        };
    }
};

// The name prefix that marks a fuzz entry point: a harness that exercises code and is not code
// somebody wrote to be exercised.
pub const fuzz_prefix = "fuzz_";

// The ending of a sim file's name.
pub const sim_suffix = ".sim.zig";

// The ending of a unit test file's name.
pub const test_suffix = ".test.zig";

// The ending of a sim file's own unit test file.
pub const sim_test_suffix = ".sim.test.zig";

// The reason a file is skipped because of its name alone, or null when its name allows it. The
// order matters: a `.sim.test.zig` also ends in `.test.zig`, so it is asked first.
pub fn reasonForName(name: []const u8) ?Reason {
    if (std.mem.eql(u8, name, "build.zig")) {
        return .build_script;
    }
    if (std.mem.eql(u8, name, "build.zig.zon")) {
        return .build_manifest;
    }
    if (!std.mem.endsWith(u8, name, ".zig")) {
        return .not_zig_file;
    }
    if (std.mem.endsWith(u8, name, sim_test_suffix)) {
        return .sim_test_file;
    }
    if (std.mem.endsWith(u8, name, test_suffix)) {
        return .test_file;
    }
    if (std.mem.startsWith(u8, name, fuzz_prefix)) {
        return .fuzz_file;
    }
    return null;
}

// Whether a file name is a sim file's.
pub fn isSimName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, sim_suffix);
}

// Whether `path` is `entry` or lies below it. An empty entry is the project root, which every path
// is under.
pub fn isUnder(entry: []const u8, path: []const u8) bool {
    if (entry.len == 0) {
        return true;
    }
    if (std.mem.eql(u8, entry, path)) {
        return true;
    }
    return path.len > entry.len and std.mem.startsWith(u8, path, entry) and path[entry.len] == '/';
}

// Whether `path` is `entry` or lies below any of `entries`.
pub fn isUnderOneOf(entries: []const []const u8, path: []const u8) bool {
    for (entries) |entry| {
        if (isUnder(entry, path)) {
            return true;
        }
    }
    return false;
}

// A path from the user with a leading `./` and trailing `/` taken off, so it compares equal to the
// paths the walk builds. A slice of its argument.
pub fn trimPath(path: []const u8) []const u8 {
    var text = path;
    while (std.mem.startsWith(u8, text, "./")) {
        text = text[2..];
    }
    while (text.len > 0 and text[text.len - 1] == '/') {
        text = text[0 .. text.len - 1];
    }
    if (std.mem.eql(u8, text, ".")) {
        return "";
    }
    return text;
}

// The directory names a walk stays out of, read from `.gitignore` rather than listed here: what is
// not ours to build (a cache, a package download, a build output) is already named there, so this
// stays right when one is added. Only plain directory names are taken; a pattern is left to git.
//
// The caller owns what comes back and `freeNames` releases it.
pub fn ignoredDirectoryNames(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir) std.mem.Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |name| {
            allocator.free(name);
        }
        names.deinit(allocator);
    }

    const source = root.readFileAlloc(io, ".gitignore", allocator, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return names.toOwnedSlice(allocator),
    };
    defer allocator.free(source);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }
        const name = std.mem.trim(u8, trimmed, "/");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "*?[!") != null or std.mem.indexOfScalar(u8, name, '/') != null) {
            continue;
        }
        try names.append(allocator, try allocator.dupe(u8, name));
    }

    return names.toOwnedSlice(allocator);
}

// Releases a list of names this file handed back.
pub fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}

// Whether `name` is one of the ignored directory names.
pub fn isIgnored(ignored: []const []const u8, name: []const u8) bool {
    for (ignored) |entry| {
        if (std.mem.eql(u8, entry, name)) {
            return true;
        }
    }
    return false;
}

// Whether `relative` is the root of a linked git worktree: one whose own `.git` is a file naming
// where the real one lives, rather than a directory. A linked worktree for a branch in progress can
// sit inside a checkout with its code half edited and its own run is the one that answers for it.
pub fn isWorktreeRoot(io: std.Io, root: std.Io.Dir, relative: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const git_path = std.fmt.bufPrint(&buffer, "{s}/.git", .{relative}) catch return false;
    const stat = root.statFile(io, git_path, .{}) catch return false;
    return stat.kind == .file;
}

// Whether a source is simulation code or a harness: it imports the framework. Tokenized rather
// than searched for as text, because the text can appear inside a string literal in code that is
// not a harness at all.
pub fn isHarness(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var import_seen = false;
    var open_seen = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .builtin => {
                import_seen = std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import");
                open_seen = false;
            },
            .l_paren => {
                open_seen = import_seen;
            },
            .string_literal => {
                if (import_seen and open_seen and std.mem.eql(u8, source[token.loc.start..token.loc.end], framework_module)) {
                    return true;
                }
                import_seen = false;
                open_seen = false;
            },
            else => {
                import_seen = false;
                open_seen = false;
            },
        }
    }
}

// Whether a source is valid Zig at all. A repository can hold a file named `.zig` that is not: a
// generated record, a template. It cannot be fault tested and it would stop the whole program
// compiling, so the walk leaves it out.
pub fn parsesAsZig(allocator: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error!bool {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return false;
    }

    // A file whose top level holds anything but declarations is not a Zig module: a list of names,
    // a record, a template. It parses and then the compiler refuses it as a tuple.
    for (tree.rootDecls()) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl,
            .fn_proto,
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            .@"comptime",
            .test_decl,
            => {},
            else => return false,
        }
    }
    return true;
}

test {
    _ = @import("skip_rules.test.zig");
}
