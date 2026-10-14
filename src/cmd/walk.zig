// The one walk over a project that decides which files Faultline reads. It answers two questions
// from the same pass so they cannot disagree: which files were found (`collect`) and what happened
// to every file and directory the walk met, taken or skipped, with the reason (`report`).
//
// Everything takes an allocator, an `Io` and a directory, so it can be pointed at a fixture tree.

const std = @import("std");
const rules = @import("skip_rules.zig");

pub const Reason = rules.Reason;

// Which paths to take and which to leave out. Every entry is a path to a file or a directory,
// relative to the project root. A directory covers everything below it.
pub const Selection = struct {
    // Where to look. Naming any entry turns off the default search, so only what is named is taken.
    // Empty means search the whole project.
    include: []const []const u8 = &.{},

    // What to leave out. It wins over `include`: a path below an excluded entry is never taken.
    exclude: []const []const u8 = &.{},
};

// What a taken file is for.
pub const Kind = enum {
    // Code to fault test.
    source,

    // A `.sim.zig` file holding value factories, scenarios and expectation functions.
    sim,
};

// One file the walk took.
pub const Found = struct {
    // The path relative to the project root, with `/` separators.
    path: []const u8,

    // What the file is for.
    kind: Kind,

    // The file it is paired with, also taken: for a `<name>.sim.zig` the `<name>.zig` beside it, and
    // for a `<name>.zig` the `<name>.sim.zig` beside it. Null when there is no pair among the files
    // taken.
    partner: ?[]const u8 = null,
};

// What happened to one file or directory the walk met.
pub const Record = struct {
    // The path relative to the project root, with `/` separators. `.` is the project root.
    path: []const u8,

    // Whether the path is a directory.
    is_directory: bool,

    // Why it was taken or skipped.
    reason: Reason,
};

// Everything one walk found out.
pub const Survey = struct {
    // The files taken, in path order.
    files: []Found,

    // Every file and directory met, in the order the walk met them. Plain files that are not Zig
    // source are left out, because listing every document in a project helps nobody.
    records: []Record,

    // Releases both lists.
    pub fn deinit(result: Survey, allocator: std.mem.Allocator) void {
        freeFiles(allocator, result.files);
        freeRecords(allocator, result.records);
    }
};

// The files taken under `project_dir`, in path order. The caller owns the list and `freeFiles`
// releases it.
pub fn collect(allocator: std.mem.Allocator, io: std.Io, project_dir: std.Io.Dir, selection: Selection) ![]Found {
    const survey_result = try survey(allocator, io, project_dir, selection);
    freeRecords(allocator, survey_result.records);
    return survey_result.files;
}

// What the walk did with every file and directory it met. The caller owns the list and `freeRecords`
// releases it.
pub fn report(allocator: std.mem.Allocator, io: std.Io, project_dir: std.Io.Dir, selection: Selection) ![]Record {
    const survey_result = try survey(allocator, io, project_dir, selection);
    freeFiles(allocator, survey_result.files);
    return survey_result.records;
}

// Releases a list `collect` returned.
pub fn freeFiles(allocator: std.mem.Allocator, files: []const Found) void {
    for (files) |file| {
        allocator.free(file.path);
        if (file.partner) |partner| {
            allocator.free(partner);
        }
    }
    allocator.free(files);
}

// Releases a list `report` returned.
pub fn freeRecords(allocator: std.mem.Allocator, records: []const Record) void {
    for (records) |record| {
        allocator.free(record.path);
    }
    allocator.free(records);
}

// The state of one walk.
const Walk = struct {
    // Where everything is allocated.
    allocator: std.mem.Allocator,

    // The I/O interface used to read the project.
    io: std.Io,

    // The project root.
    root: std.Io.Dir,

    // What to leave out, with every entry already trimmed.
    exclude: []const []const u8,

    // Directory names from `.gitignore`.
    ignored: []const []const u8,

    // The files taken so far.
    files: std.ArrayList(Found) = .empty,

    // What happened to everything met so far.
    records: std.ArrayList(Record) = .empty,

    // The paths already met, so a path named twice (a directory and a file inside it) is handled
    // once.
    met: std.StringHashMapUnmanaged(void) = .empty,

    // Records one path and what happened to it.
    fn note(walk: *Walk, path: []const u8, is_directory: bool, reason: Reason) !void {
        const owned = try walk.allocator.dupe(u8, path);
        errdefer walk.allocator.free(owned);
        try walk.records.append(walk.allocator, .{ .path = owned, .is_directory = is_directory, .reason = reason });
    }

    // Whether a path has been met already and if not, remembers it.
    fn hasMet(walk: *Walk, path: []const u8) !bool {
        if (walk.met.contains(path)) {
            return true;
        }
        const owned = try walk.allocator.dupe(u8, path);
        errdefer walk.allocator.free(owned);
        try walk.met.put(walk.allocator, owned, {});
        return false;
    }

    // Walks one directory. A directory the user named is searched whatever its name, because naming
    // it is the request.
    fn visitDirectory(walk: *Walk, relative: []const u8, was_named: bool) anyerror!void {
        if (relative.len != 0) {
            if (try walk.hasMet(relative)) {
                return;
            }
            if (rules.isUnderOneOf(walk.exclude, relative)) {
                try walk.note(relative, true, .excluded);
                return;
            }
            const name = std.fs.path.basename(relative);
            if (!was_named) {
                if (std.mem.startsWith(u8, name, ".")) {
                    try walk.note(relative, true, .dot_directory);
                    return;
                }
                if (rules.isIgnored(walk.ignored, name)) {
                    try walk.note(relative, true, .ignored_directory);
                    return;
                }
                if (rules.isWorktreeRoot(walk.io, walk.root, relative)) {
                    try walk.note(relative, true, .worktree_root);
                    return;
                }
            }
        }

        try walk.note(if (relative.len == 0) "." else relative, true, .searched_directory);

        var directory = try walk.root.openDir(walk.io, if (relative.len == 0) "." else relative, .{ .iterate = true });
        defer directory.close(walk.io);

        const Entry = struct { name: []const u8, is_directory: bool };
        var entries: std.ArrayList(Entry) = .empty;
        defer {
            for (entries.items) |entry| {
                walk.allocator.free(entry.name);
            }
            entries.deinit(walk.allocator);
        }
        var iterator = directory.iterate();
        while (try iterator.next(walk.io)) |entry| {
            const is_directory = switch (entry.kind) {
                .directory => true,
                .file => false,
                else => continue,
            };
            try entries.append(walk.allocator, .{ .name = try walk.allocator.dupe(u8, entry.name), .is_directory = is_directory });
        }
        // Sorted so two walks over one tree meet things in one order, whatever order the disk lists.
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        for (entries.items) |entry| {
            const below = try joinPath(walk.allocator, relative, entry.name);
            defer walk.allocator.free(below);
            if (entry.is_directory) {
                try walk.visitDirectory(below, false);
            } else {
                try walk.visitFile(below, false);
            }
        }
    }

    // Decides one file. A file the user named gets a record even when it is not Zig source, because
    // they asked about it by name.
    fn visitFile(walk: *Walk, relative: []const u8, was_named: bool) !void {
        if (try walk.hasMet(relative)) {
            return;
        }
        const name = std.fs.path.basename(relative);

        if (rules.isUnderOneOf(walk.exclude, relative)) {
            if (was_named or std.mem.endsWith(u8, name, ".zig")) {
                try walk.note(relative, false, .excluded);
            }
            return;
        }
        if (rules.reasonForName(name)) |reason| {
            if (reason == .not_zig_file and !was_named) {
                return;
            }
            try walk.note(relative, false, reason);
            return;
        }

        const source = walk.root.readFileAllocOptions(walk.io, relative, walk.allocator, .unlimited, .of(u8), 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try walk.note(relative, false, .unreadable);
                return;
            },
        };
        defer walk.allocator.free(source);

        if (!try rules.parsesAsZig(walk.allocator, source)) {
            try walk.note(relative, false, .does_not_parse);
            return;
        }
        const is_sim = rules.isSimName(name);
        if (!is_sim and rules.isHarness(source)) {
            try walk.note(relative, false, .imports_framework);
            return;
        }

        const owned = try walk.allocator.dupe(u8, relative);
        errdefer walk.allocator.free(owned);
        try walk.files.append(walk.allocator, .{ .path = owned, .kind = if (is_sim) .sim else .source });
        try walk.note(relative, false, if (is_sim) .taken_sim else .taken_source);
    }

    // Visits one path the user named: a directory, a file, or something that is not there.
    fn visitNamed(walk: *Walk, relative: []const u8) !void {
        if (relative.len == 0) {
            try walk.visitDirectory("", true);
            return;
        }
        const stat = walk.root.statFile(walk.io, relative, .{}) catch {
            if (!try walk.hasMet(relative)) {
                try walk.note(relative, false, .not_found);
            }
            return;
        };
        switch (stat.kind) {
            .directory => try walk.visitDirectory(relative, true),
            .file => try walk.visitFile(relative, true),
            else => {
                if (!try walk.hasMet(relative)) {
                    try walk.note(relative, false, .not_found);
                }
            },
        }
    }
};

// One walk over the project, answering both what was taken and what happened to everything met. The
// caller owns the result and `Survey.deinit` releases it.
pub fn survey(allocator: std.mem.Allocator, io: std.Io, project_dir: std.Io.Dir, selection: Selection) !Survey {
    const ignored = try rules.ignoredDirectoryNames(allocator, io, project_dir);
    defer rules.freeNames(allocator, ignored);

    const include = try trimAll(allocator, selection.include);
    defer allocator.free(include);
    const exclude = try trimAll(allocator, selection.exclude);
    defer allocator.free(exclude);

    var walk: Walk = .{
        .allocator = allocator,
        .io = io,
        .root = project_dir,
        .exclude = exclude,
        .ignored = ignored,
    };
    defer {
        var keys = walk.met.keyIterator();
        while (keys.next()) |key| {
            allocator.free(key.*);
        }
        walk.met.deinit(allocator);
    }
    errdefer {
        for (walk.files.items) |file| {
            allocator.free(file.path);
        }
        walk.files.deinit(allocator);
        for (walk.records.items) |record| {
            allocator.free(record.path);
        }
        walk.records.deinit(allocator);
    }

    if (include.len == 0) {
        try walk.visitNamed("");
    } else {
        for (include) |entry| {
            try walk.visitNamed(entry);
        }
    }

    std.mem.sort(Found, walk.files.items, {}, struct {
        fn lessThan(_: void, a: Found, b: Found) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    try pairFiles(allocator, walk.files.items);

    const files = try walk.files.toOwnedSlice(allocator);
    errdefer freeFiles(allocator, files);
    const records = try walk.records.toOwnedSlice(allocator);
    return .{ .files = files, .records = records };
}

// Fills in `partner` for each file that has its pair among the files taken.
fn pairFiles(allocator: std.mem.Allocator, files: []Found) !void {
    for (files) |*file| {
        const wanted = try pairPathOf(allocator, file.path, file.kind);
        defer allocator.free(wanted);
        for (files) |other| {
            if (std.mem.eql(u8, other.path, wanted)) {
                file.partner = try allocator.dupe(u8, wanted);
                break;
            }
        }
    }
}

// The path a file's pair would have: `a/b.sim.zig` gives `a/b.zig` and `a/b.zig` gives `a/b.sim.zig`.
fn pairPathOf(allocator: std.mem.Allocator, path: []const u8, kind: Kind) ![]u8 {
    switch (kind) {
        .sim => {
            return std.fmt.allocPrint(allocator, "{s}.zig", .{path[0 .. path.len - rules.sim_suffix.len]});
        },
        .source => {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0 .. path.len - ".zig".len], rules.sim_suffix });
        },
    }
}

// Trims every user path. The strings are slices of the argument, so only the list is allocated.
fn trimAll(allocator: std.mem.Allocator, paths: []const []const u8) ![][]const u8 {
    const trimmed = try allocator.alloc([]const u8, paths.len);
    for (paths, 0..) |path, index| {
        trimmed[index] = rules.trimPath(path);
    }
    return trimmed;
}

// A directory path and a name joined with `/`, where an empty directory is the project root.
fn joinPath(allocator: std.mem.Allocator, directory: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    if (directory.len == 0) {
        return allocator.dupe(u8, name);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
}

test {
    _ = @import("walk.test.zig");
}
