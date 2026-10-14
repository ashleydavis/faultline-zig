// Tests for the in-memory filesystem, driven through `std.Io.Dir` and `std.Io.File` the way the code
// under test drives it. The first part checks how the filesystem behaves with nothing injected. The
// second part injects the failure of each row of `docs/FAILURES.md` that belongs to a call here and
// checks what the call returns, with a test that shows the sequence where a row needs more than one
// call.

const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector_mod = @import("injector.zig");
const filesystem = @import("filesystem.zig");

const Dir = std.Io.Dir;
const File = std.Io.File;
const testing = std.testing;

// One installed filesystem over a real `Io`, with the injector it asks. The `Io` underneath is a
// real one because the layering must leave everything that is not a file as it was.
const World = struct {
    // The real implementation the filesystem is layered over.
    threaded: std.Io.Threaded,

    // The room the installed vtable is written into.
    room: std.Io.VTable,

    // What decides which calls fail.
    injector: injector_mod.Injector,

    // The `Io` the code under test is given.
    io: std.Io,

    // Installs the filesystem over a fresh `Io` and an empty tree, failing the places in `plan`.
    fn create(self: *World, plan: []const injector_mod.Injection) void {
        self.threaded = std.Io.Threaded.init(testing.allocator, .{});
        self.injector = injector_mod.Injector.init(testing.allocator, plan);
        filesystem.reset();
        self.io = filesystem.install(self.threaded.io(), &self.room, &self.injector);
    }

    // Lets go of everything the world holds.
    fn destroy(self: *World) void {
        self.injector.deinit();
        self.threaded.deinit();
        filesystem.reset();
    }
};

// The failure that makes the `occurrence`-th call of `effect` fail as the row `id` says. A row that
// is not in `injected_rows` is a mistake in the test, because that list is what the last test
// checks against the table.
fn at(effect: point.Effect, occurrence: u32, id: []const u8) injector_mod.Injection {
    for (injected_rows) |row| {
        if (row.effect == effect and std.mem.eql(u8, row.id, id)) {
            break;
        }
    } else {
        @panic("the row is not in injected_rows");
    }
    for (failures.kindsOf(effect), 0..) |kind, index| {
        if (std.mem.eql(u8, kind.id, id)) {
            return .{ .point = .{ .effect = effect, .occurrence = occurrence }, .kind = @intCast(index) };
        }
    }
    @panic("no such failure id in the test");
}

// Fills a tree most tests start from: a file, a directory of three files, a link to the file and an
// empty directory.
fn seed() !void {
    try filesystem.makeFile("f.txt", "0123456789");
    try filesystem.makeFile("dir/a.txt", "a");
    try filesystem.makeFile("dir/b.txt", "b");
    try filesystem.makeFile("dir/c.txt", "c");
    try filesystem.makeSymlink("f.txt", "link");
    try filesystem.makeDirectory("empty");
}

// An operation on a world, for the tests that run one operation once per failure row.
const Operation = *const fn (*World) anyerror!void;

// One failure row, the error it should make an operation return and the operation to run.
const Case = struct {
    // The id of the row in the table.
    id: []const u8,

    // The error the call returns when the row is injected.
    expected: anyerror,

    // Runs the call.
    run: Operation,
};

// Runs each case in a world of its own with the row injected at the first call of `effect` and
// checks the call returns the error the row says. Then runs it again with nothing injected and
// checks the call can succeed, so the failure is the injection's and not the setup's.
fn expectEveryCase(effect: point.Effect, comptime cases: []const Case) !void {
    for (cases) |case| {
        const plan = [_]injector_mod.Injection{at(effect, 0, case.id)};
        var world: World = undefined;
        world.create(&plan);
        defer world.destroy();
        try seed();
        testing.expectError(case.expected, case.run(&world)) catch |err| {
            std.debug.print("row '{s}' did not return {s}\n", .{ case.id, @errorName(case.expected) });
            return err;
        };
        try testing.expectEqual(@as(usize, 1), world.injector.recorded.items.len - countOtherEffects(&world, effect));
    }
}

// How many of the places an injector recorded were not for `effect`.
fn countOtherEffects(world: *World, effect: point.Effect) usize {
    var other: usize = 0;
    for (world.injector.recorded.items) |place| {
        if (place.point.effect != effect) {
            other += 1;
        }
    }
    return other;
}

// Reads a whole file through the world's own `Io`.
fn readAll(world: *World, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(world.io, path, testing.allocator, .unlimited);
}

// Behaviour with nothing injected.

test "a file written is read back and nothing reaches the real disk" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.writeFile(world.io, .{ .sub_path = "notes.txt", .data = "what it said" });
    const read = try readAll(&world, "notes.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("what it said", read);

    // The name is one no test would create on purpose, so a file of it on disk would mean this
    // wrote through to the real filesystem.
    var real = std.Io.Threaded.init(testing.allocator, .{});
    defer real.deinit();
    try testing.expectError(error.FileNotFound, Dir.cwd().access(real.io(), "notes.txt", .{}));
}

test "a file written twice keeps only what was written last" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.writeFile(world.io, .{ .sub_path = "once.txt", .data = "the long first thing" });
    try cwd.writeFile(world.io, .{ .sub_path = "once.txt", .data = "short" });
    const read = try readAll(&world, "once.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("short", read);
}

test "a file nothing wrote is not found" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try testing.expectError(error.FileNotFound, readAll(&world, "nowhere.txt"));
}

test "a path is made a directory at a time and a file under it is found" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.createDirPath(world.io, "src/lib/deep");
    try cwd.writeFile(world.io, .{ .sub_path = "src/lib/deep/thing.zig", .data = "const a = 1;" });

    const stat = try cwd.statFile(world.io, "src/lib/deep/thing.zig", .{});
    try testing.expectEqual(@as(u64, 12), stat.size);
    try testing.expectEqual(File.Kind.file, stat.kind);
    const above = try cwd.statFile(world.io, "src/lib", .{});
    try testing.expectEqual(File.Kind.directory, above.kind);
}

test "createDirPath says whether it made anything and refuses an empty path" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try testing.expectEqual(Dir.CreatePathStatus.created, try cwd.createDirPathStatus(world.io, "a/b", .default_dir));
    try testing.expectEqual(Dir.CreatePathStatus.existed, try cwd.createDirPathStatus(world.io, "a/b", .default_dir));
    try testing.expectError(error.BadPathName, cwd.createDirPath(world.io, ""));
}

test "createDirPathOpen makes a directory and opens it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var dir = try Dir.cwd().createDirPathOpen(world.io, "x/y", .{});
    defer dir.close(world.io);
    try dir.writeFile(world.io, .{ .sub_path = "inside.txt", .data = "in" });
    try testing.expect(filesystem.exists("x/y/inside.txt"));
}

test "createDir makes one directory and needs its parent" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.createDir(world.io, "one", .default_dir);
    try testing.expectError(error.PathAlreadyExists, cwd.createDir(world.io, "one", .default_dir));
    try testing.expectError(error.FileNotFound, cwd.createDir(world.io, "missing/child", .default_dir));
}

test "a directory lists what is directly inside it in sorted order and nothing below that" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try filesystem.makeDirectory("project/below");
    try cwd.writeFile(world.io, .{ .sub_path = "project/two.txt", .data = "" });
    try cwd.writeFile(world.io, .{ .sub_path = "project/one.txt", .data = "" });
    try cwd.writeFile(world.io, .{ .sub_path = "project/below/three.txt", .data = "" });
    try cwd.writeFile(world.io, .{ .sub_path = "project/Zed.txt", .data = "" });

    var dir = try cwd.openDir(world.io, "project", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    const expected = [_][]const u8{ "Zed.txt", "below", "one.txt", "two.txt" };
    var seen: usize = 0;
    while (try iterator.next(world.io)) |entry| {
        try testing.expectEqualStrings(expected[seen], entry.name);
        seen += 1;
    }
    try testing.expectEqual(expected.len, seen);
}

test "a listing reports the kind of each entry, including links" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, ".", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    var kinds: [4]File.Kind = undefined;
    var count: usize = 0;
    while (try iterator.next(world.io)) |entry| {
        kinds[count] = entry.kind;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 4), count);

    // Sorted: dir, empty, f.txt, link.
    try testing.expectEqual(File.Kind.directory, kinds[0]);
    try testing.expectEqual(File.Kind.directory, kinds[1]);
    try testing.expectEqual(File.Kind.file, kinds[2]);
    try testing.expectEqual(File.Kind.sym_link, kinds[3]);
}

test "a listing run twice gives the same order, so a replay sees the same thing" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    for ([_][]const u8{ "m", "c", "x", "a", "q" }) |name| {
        try filesystem.makeFile(name, "");
    }

    const first = try filesystem.listDirectory(testing.allocator, ".");
    defer filesystem.freeNames(testing.allocator, first);
    const second = try filesystem.listDirectory(testing.allocator, ".");
    defer filesystem.freeNames(testing.allocator, second);
    try testing.expectEqual(first.len, second.len);
    for (first, second) |one, other| {
        try testing.expectEqualStrings(one, other);
    }
    try testing.expectEqualStrings("a", first[0]);
    try testing.expectEqualStrings("x", first[4]);
}

test "a directory read in several calls hands each entry over once" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, "dir", .{ .iterate = true });
    defer dir.close(world.io);
    var buffer: [Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
    var reader = Dir.Reader.init(dir, &buffer);
    var entries: [2]Dir.Entry = undefined;
    try testing.expectEqual(@as(usize, 2), try reader.read(world.io, &entries));
    try testing.expectEqualStrings("a.txt", entries[0].name);
    try testing.expectEqualStrings("b.txt", entries[1].name);
    try testing.expectEqual(@as(usize, 1), try reader.read(world.io, &entries));
    try testing.expectEqualStrings("c.txt", entries[0].name);
    try testing.expectEqual(@as(usize, 0), try reader.read(world.io, &entries));
    try testing.expectEqual(Dir.Reader.State.finished, reader.state);

    // Reset starts the listing again from the first entry.
    reader.reset();
    try testing.expectEqual(@as(usize, 2), try reader.read(world.io, &entries));
}

test "a deleted file is gone and a directory holding something refuses to go" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try filesystem.makeDirectory("held");
    try cwd.writeFile(world.io, .{ .sub_path = "held/inside.txt", .data = "" });
    try testing.expectError(error.DirNotEmpty, cwd.deleteDir(world.io, "held"));
    try testing.expectError(error.IsDir, cwd.deleteFile(world.io, "held"));
    try cwd.deleteFile(world.io, "held/inside.txt");
    try testing.expectError(error.FileNotFound, cwd.statFile(world.io, "held/inside.txt", .{}));
    try cwd.deleteDir(world.io, "held");
    try testing.expectError(error.FileNotFound, cwd.statFile(world.io, "held", .{}));
    try testing.expectError(error.FileNotFound, cwd.deleteFile(world.io, "held"));
    try testing.expectError(error.FileNotFound, cwd.deleteDir(world.io, "held"));
}

test "deleteDir refuses a file and the root" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try testing.expectError(error.NotDir, Dir.cwd().deleteDir(world.io, "f.txt"));
    try testing.expectError(error.FileBusy, Dir.cwd().deleteDir(world.io, "/"));
}

test "a rename moves a file and replaces whatever was in its way" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.writeFile(world.io, .{ .sub_path = "written.tmp", .data = "the new contents" });
    try cwd.writeFile(world.io, .{ .sub_path = "real.txt", .data = "the old contents" });
    try cwd.rename("written.tmp", cwd, "real.txt", world.io);

    const read = try readAll(&world, "real.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("the new contents", read);
    try testing.expectError(error.FileNotFound, cwd.statFile(world.io, "written.tmp", .{}));
}

test "a rename moves a directory with what is in it and refuses to move it into itself" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.rename("dir", cwd, "moved", world.io);
    try testing.expect(filesystem.exists("moved/a.txt"));
    try testing.expect(!filesystem.exists("dir"));
    try testing.expectError(error.Unexpected, cwd.rename("moved", cwd, "moved/inside", world.io));
}

test "a rename keeps a file and a directory apart" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try testing.expectError(error.IsDir, cwd.rename("f.txt", cwd, "dir", world.io));
    try testing.expectError(error.NotDir, cwd.rename("dir", cwd, "f.txt", world.io));
    try testing.expectError(error.DirNotEmpty, cwd.rename("empty", cwd, "dir", world.io));
    try testing.expectError(error.FileNotFound, cwd.rename("nowhere", cwd, "x", world.io));
}

test "renamePreserve refuses to replace a name that is taken" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try testing.expectError(error.PathAlreadyExists, cwd.renamePreserve("f.txt", cwd, "dir/a.txt", world.io));
    try cwd.renamePreserve("f.txt", cwd, "fresh.txt", world.io);
    try testing.expect(filesystem.exists("fresh.txt"));
}

test "resetting empties the tree, so one call never sees what another wrote" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try Dir.cwd().writeFile(world.io, .{ .sub_path = "from-the-last-call.txt", .data = "" });
    filesystem.reset();
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(world.io, "from-the-last-call.txt", .{}));
}

test "an absolute path names itself and a relative one hangs off the current directory" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try filesystem.makeDirectory("/tmp/made-up");
    try cwd.writeFile(world.io, .{ .sub_path = "/tmp/made-up/thing.txt", .data = "held" });
    const read = try readAll(&world, "/tmp/made-up/thing.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("held", read);
    try testing.expect(filesystem.exists("/tmp/made-up/thing.txt"));

    // A path with "." and ".." steps names the same file.
    const again = try readAll(&world, "/tmp/./made-up/../made-up/thing.txt");
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("held", again);
}

test "a read-only directory refuses a new file and allows one again when it is not" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.createDirPath(world.io, "locked");
    try cwd.setFilePermissions(world.io, "locked", File.Permissions.default_dir.setReadOnly(true), .{});
    try testing.expectError(error.AccessDenied, cwd.writeFile(world.io, .{ .sub_path = "locked/new.txt", .data = "" }));
    try cwd.setFilePermissions(world.io, "locked", File.Permissions.default_dir, .{});
    try cwd.writeFile(world.io, .{ .sub_path = "locked/new.txt", .data = "" });
}

test "a read-only file refuses to be opened for writing and can still be read" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.writeFile(world.io, .{ .sub_path = "fixed.txt", .data = "what it says" });
    try cwd.setFilePermissions(world.io, "fixed.txt", File.Permissions.default_file.setReadOnly(true), .{});
    try testing.expectError(error.AccessDenied, cwd.writeFile(world.io, .{ .sub_path = "fixed.txt", .data = "else" }));
    try testing.expectError(error.AccessDenied, cwd.openFile(world.io, "fixed.txt", .{ .mode = .read_write }));

    const read = try readAll(&world, "fixed.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("what it says", read);
}

test "a file nobody may read refuses to be opened for reading" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeFile("secret.txt", "x");
    try filesystem.setMode("secret.txt", 0o000);
    try testing.expectError(error.AccessDenied, readAll(&world, "secret.txt"));
}

test "a directory that cannot be searched refuses a path through it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeFile("closed/inside.txt", "x");
    try filesystem.setMode("closed", 0o600);
    try testing.expectError(error.AccessDenied, readAll(&world, "closed/inside.txt"));
}

test "a directory that cannot be read refuses to be opened" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeDirectory("hidden");
    try filesystem.setMode("hidden", 0o300);
    try testing.expectError(error.AccessDenied, Dir.cwd().openDir(world.io, "hidden", .{}));
}

test "a read-only directory refuses to have something deleted from it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try filesystem.makeDirectory("kept");
    try cwd.writeFile(world.io, .{ .sub_path = "kept/inside.txt", .data = "" });
    try cwd.setFilePermissions(world.io, "kept", File.Permissions.default_dir.setReadOnly(true), .{});
    try testing.expectError(error.AccessDenied, cwd.deleteFile(world.io, "kept/inside.txt"));
}

test "a path below a file is refused as not a directory and not as missing" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.writeFile(world.io, .{ .sub_path = "a-file", .data = "not a directory" });
    try testing.expectError(error.NotDir, cwd.statFile(world.io, "a-file/below", .{}));
    try testing.expectError(error.NotDir, cwd.createDirPath(world.io, "a-file/below"));
    try testing.expectError(error.NotDir, cwd.openDir(world.io, "a-file", .{}));
    try testing.expectError(error.FileNotFound, cwd.access(world.io, "a-file/below", .{}));
}

test "a name that is too long is refused" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const long = "n" ** (Dir.max_name_bytes + 1);
    try testing.expectError(error.NameTooLong, Dir.cwd().statFile(world.io, long, .{}));
}

test "a file just written is recent and a timestamp can be set back" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try cwd.writeFile(world.io, .{ .sub_path = "fresh.lock", .data = "" });
    const stat = try cwd.statFile(world.io, "fresh.lock", .{});
    const now = std.Io.Clock.Timestamp.now(world.io, .real).raw;
    try testing.expect(now.nanoseconds - stat.mtime.nanoseconds < std.time.ns_per_s);

    var file = try cwd.openFile(world.io, "fresh.lock", .{ .mode = .read_write });
    defer file.close(world.io);
    try file.setTimestamps(world.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1 } } });
    const back = try cwd.statFile(world.io, "fresh.lock", .{});
    try testing.expectEqual(@as(i96, 1), back.mtime.nanoseconds);

    // A write after that makes it recent again.
    try file.writePositionalAll(world.io, "x", 0);
    const written = try cwd.statFile(world.io, "fresh.lock", .{});
    try testing.expect(written.mtime.nanoseconds > 1);
}

test "setTimestamps by path and with now change the times" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.setTimestamps(world.io, "f.txt", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 5 } }, .access_timestamp = .{ .new = .{ .nanoseconds = 7 } } });
    const stat = try cwd.statFile(world.io, "f.txt", .{});
    try testing.expectEqual(@as(i96, 5), stat.mtime.nanoseconds);
    try testing.expectEqual(@as(i96, 7), stat.atime.?.nanoseconds);

    var file = try cwd.openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try file.setTimestampsNow(world.io);
    const fresh = try cwd.statFile(world.io, "f.txt", .{});
    try testing.expect(fresh.mtime.nanoseconds > 5);
    try testing.expectError(error.Unexpected, cwd.setTimestamps(world.io, "nowhere", .{}));
}

test "setFilePermissions changes the mode stat reports, by path and by handle" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.setFilePermissions(world.io, "f.txt", File.Permissions.fromMode(0o640), .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o640), (try cwd.statFile(world.io, "f.txt", .{})).permissions.toMode());

    var file = try cwd.openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try file.setPermissions(world.io, File.Permissions.fromMode(0o600));
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), (try file.stat(world.io)).permissions.toMode());

    var dir = try cwd.openDir(world.io, "dir", .{});
    defer dir.close(world.io);
    try dir.setPermissions(world.io, File.Permissions.fromMode(0o700));
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), (try dir.stat(world.io)).permissions.toMode());
    try testing.expectError(error.FileNotFound, cwd.setFilePermissions(world.io, "nowhere", .default_file, .{}));
    try testing.expectError(error.OperationUnsupported, cwd.setFilePermissions(world.io, "link", .default_file, .{ .follow_symlinks = false }));
}

test "setOwner records the owner and group by handle and by path" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    var file = try cwd.openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try file.setOwner(world.io, 1000, 1000);
    try world.io.vtable.dirSetFileOwner(world.io.userdata, cwd, "f.txt", 1001, null, .{});
    var dir = try cwd.openDir(world.io, "dir", .{});
    defer dir.close(world.io);
    try dir.setOwner(world.io, null, 50);
    try testing.expectError(error.FileNotFound, world.io.vtable.dirSetFileOwner(world.io.userdata, cwd, "nowhere", 1, 1, .{}));
}

test "stat reports the size, kind, link count and permissions of a file" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const stat = try Dir.cwd().statFile(world.io, "f.txt", .{});
    try testing.expectEqual(@as(u64, 10), stat.size);
    try testing.expectEqual(File.Kind.file, stat.kind);
    try testing.expectEqual(@as(@TypeOf(stat.nlink), 1), stat.nlink);
    var other = try Dir.cwd().statFile(world.io, "dir/a.txt", .{});
    try testing.expect(stat.inode != other.inode);
    other = try Dir.cwd().statFile(world.io, "dir", .{});
    try testing.expectEqual(File.Kind.directory, other.kind);
}

test "an open file reports its length and stat and the length follows writes" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .read_write });
    defer file.close(world.io);
    try testing.expectEqual(@as(u64, 10), try file.length(world.io));
    try file.writePositionalAll(world.io, "abc", 20);
    try testing.expectEqual(@as(u64, 23), try file.length(world.io));
    try testing.expectEqual(@as(u64, 23), (try file.stat(world.io)).size);

    // The gap between the old end and the write is zeros.
    var buffer: [13]u8 = undefined;
    _ = try file.readPositionalAll(world.io, &buffer, 10);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 10 ++ "abc".*), &buffer);
}

test "an open directory reports its own stat" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, "dir", .{});
    defer dir.close(world.io);
    try testing.expectEqual(File.Kind.directory, (try dir.stat(world.io)).kind);
}

test "setLength shortens and lengthens a file" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .read_write });
    defer file.close(world.io);
    try file.setLength(world.io, 4);
    try testing.expectEqual(@as(u64, 4), try file.length(world.io));
    try file.setLength(world.io, 6);
    const read = try filesystem.readContents(testing.allocator, "f.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, "0123\x00\x00", read);
}

test "setLength on a file opened read-only is refused" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try testing.expectError(error.AccessDenied, file.setLength(world.io, 1));
}

test "a write that does not fit on the disk is out of space" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var file = try Dir.cwd().createFile(world.io, "big.bin", .{});
    defer file.close(world.io);
    try testing.expectError(error.NoSpaceLeft, file.writePositionalAll(world.io, "x", 1 << 40));
    try testing.expectError(error.FileTooBig, file.setLength(world.io, 1 << 40));
}

test "a stream reader reads a file in pieces and ends at the end" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [4]u8 = undefined;
    var reader = file.readerStreaming(world.io, &buffer);
    var out: [10]u8 = undefined;
    try reader.interface.readSliceAll(&out);
    try testing.expectEqualStrings("0123456789", &out);
    try testing.expectError(error.EndOfStream, reader.interface.readSliceAll(&out));
}

test "a positional reader reads a file and seeks" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [4]u8 = undefined;
    var reader = file.reader(world.io, &buffer);
    try reader.seekTo(6);
    var out: [4]u8 = undefined;
    try reader.interface.readSliceAll(&out);
    try testing.expectEqualStrings("6789", &out);
}

test "streaming seeks move where the next streaming read lands" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try world.io.vtable.fileSeekTo(world.io.userdata, file, 5);
    var one: [2]u8 = undefined;
    _ = try file.readStreaming(world.io, &.{&one});
    try testing.expectEqualStrings("56", &one);
    try world.io.vtable.fileSeekBy(world.io.userdata, file, 1);
    _ = try file.readStreaming(world.io, &.{&one});
    try testing.expectEqualStrings("89", &one);
    try testing.expectError(error.Unseekable, world.io.vtable.fileSeekBy(world.io.userdata, file, -100));
}

test "a streaming write lands at the position and moves it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var file = try Dir.cwd().createFile(world.io, "log.txt", .{ .read = true });
    defer file.close(world.io);
    try file.writeStreamingAll(world.io, "ab");
    try file.writeStreamingAll(world.io, "cd");
    try world.io.vtable.fileSeekTo(world.io.userdata, file, 1);
    try file.writeStreamingAll(world.io, "X");
    const read = try filesystem.readContents(testing.allocator, "log.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("aXcd", read);
}

test "a write with a header and a repeated last piece lands in order" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var file = try Dir.cwd().createFile(world.io, "pieces.txt", .{});
    defer file.close(world.io);
    const n = try file.writeStreaming(world.io, "H", &.{ "ab", "c" }, 3);
    try testing.expectEqual(@as(usize, 6), n);
    const read = try filesystem.readContents(testing.allocator, "pieces.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("Habccc", read);
}

test "an open directory read as a file is refused when it is read" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try testing.expectError(error.IsDir, readAll(&world, "dir"));
    try testing.expectError(error.IsDir, Dir.cwd().openFile(world.io, "dir", .{ .allow_directory = false }));
    try testing.expectError(error.IsDir, Dir.cwd().openFile(world.io, "dir", .{ .mode = .write_only }));
}

test "a file opened to write only refuses a read and one opened to read only refuses a write" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var writer = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .write_only });
    defer writer.close(world.io);
    var buffer: [2]u8 = undefined;
    try testing.expectError(error.NotOpenForReading, writer.readPositional(world.io, &.{&buffer}, 0));
    try testing.expectError(error.NotOpenForReading, writer.readStreaming(world.io, &.{&buffer}));

    var reader = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer reader.close(world.io);
    try testing.expectError(error.NotOpenForWriting, reader.writePositional(world.io, &.{"x"}, 0));
    try testing.expectError(error.NotOpenForWriting, reader.writeStreaming(world.io, &.{}, &.{"x"}, 1));
}

test "creating a file that must not exist refuses one that does" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try testing.expectError(error.PathAlreadyExists, Dir.cwd().createFile(world.io, "f.txt", .{ .exclusive = true }));
    try testing.expectError(error.IsDir, Dir.cwd().createFile(world.io, "dir", .{}));
    var made = try Dir.cwd().createFile(world.io, "fresh.txt", .{ .exclusive = true });
    made.close(world.io);
}

test "creating a file with truncate off keeps what was there" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().createFile(world.io, "f.txt", .{ .truncate = false });
    file.close(world.io);
    try testing.expectEqual(@as(u64, 10), (try Dir.cwd().statFile(world.io, "f.txt", .{})).size);
}

test "access checks existence and the permission asked for" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.access(world.io, "f.txt", .{ .read = true, .write = true });
    try testing.expectError(error.FileNotFound, cwd.access(world.io, "nowhere", .{}));
    try filesystem.setMode("f.txt", 0o444);
    try testing.expectError(error.AccessDenied, cwd.access(world.io, "f.txt", .{ .write = true }));
    try testing.expectError(error.AccessDenied, cwd.access(world.io, "f.txt", .{ .execute = true }));
}

// Symbolic links.

test "a symbolic link is made, read and followed when its target is opened" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.symLink(world.io, "dir", "dirlink", .{ .is_directory = true });
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const length = try cwd.readLink(world.io, "dirlink", &buffer);
    try testing.expectEqualStrings("dir", buffer[0..length]);

    // Following the link on open, on read and through the link to a file inside.
    const through = try readAll(&world, "dirlink/a.txt");
    defer testing.allocator.free(through);
    try testing.expectEqualStrings("a", through);
    const direct = try readAll(&world, "link");
    defer testing.allocator.free(direct);
    try testing.expectEqualStrings("0123456789", direct);
}

test "stat follows a link unless told not to" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    const followed = try cwd.statFile(world.io, "link", .{});
    try testing.expectEqual(File.Kind.file, followed.kind);
    try testing.expectEqual(@as(u64, 10), followed.size);
    const itself = try cwd.statFile(world.io, "link", .{ .follow_symlinks = false });
    try testing.expectEqual(File.Kind.sym_link, itself.kind);
    try testing.expectEqual(@as(u64, "f.txt".len), itself.size);
}

test "a link made with a relative target is followed from the directory the link is in" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try filesystem.makeSymlink("../f.txt", "dir/up");
    const read = try readAll(&world, "dir/up");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("0123456789", read);
    try filesystem.makeSymlink("/f.txt", "dir/absolute");
    const again = try readAll(&world, "dir/absolute");
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("0123456789", again);
}

test "a dangling link cannot be opened and can be removed" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeSymlink("nowhere", "dangling");
    try testing.expectError(error.FileNotFound, readAll(&world, "dangling"));
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(world.io, "dangling", .{}));
    const itself = try Dir.cwd().statFile(world.io, "dangling", .{ .follow_symlinks = false });
    try testing.expectEqual(File.Kind.sym_link, itself.kind);
    try Dir.cwd().deleteFile(world.io, "dangling");
    try testing.expect(filesystem.kindOf("dangling") == null);
}

test "a chain of links that returns to itself is a loop" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeSymlink("b", "a");
    try filesystem.makeSymlink("a", "b");
    try testing.expectError(error.SymLinkLoop, readAll(&world, "a"));
    try testing.expectError(error.SymLinkLoop, Dir.cwd().statFile(world.io, "b", .{}));
    try filesystem.makeSymlink("self", "self");
    try testing.expectError(error.SymLinkLoop, Dir.cwd().openDir(world.io, "self", .{}));
}

test "a chain of links that ends at a file is followed, up to the limit" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try filesystem.makeFile("end.txt", "end");

    // The link named `c<n>` points at the one before it, so following `c<n>` follows n + 1 links.
    // The chain is followed as far as the limit and one link more is a loop, as on Linux.
    const tree = @import("filesystem_tree.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var previous: []const u8 = "end.txt";
    for (0..tree.max_symlink_hops + 1) |index| {
        const name = try std.fmt.allocPrint(arena.allocator(), "c{d}", .{index});
        try filesystem.makeSymlink(previous, name);
        previous = name;
    }
    const at_limit = try std.fmt.allocPrint(arena.allocator(), "c{d}", .{tree.max_symlink_hops - 1});
    const read = try readAll(&world, at_limit);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("end", read);
    const past_limit = try std.fmt.allocPrint(arena.allocator(), "c{d}", .{tree.max_symlink_hops});
    try testing.expectError(error.SymLinkLoop, readAll(&world, past_limit));
}

test "creating a file through a dangling link makes the file the link points at" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeSymlink("target.txt", "point");
    try Dir.cwd().writeFile(world.io, .{ .sub_path = "point", .data = "made" });
    try testing.expectEqual(File.Kind.file, filesystem.kindOf("target.txt").?);
    try testing.expectEqual(File.Kind.sym_link, filesystem.kindOf("point").?);
    const read = try filesystem.readContents(testing.allocator, "target.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("made", read);
}

test "removing a link leaves its target alone" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try Dir.cwd().deleteFile(world.io, "link");
    try testing.expect(filesystem.kindOf("link") == null);
    try testing.expect(filesystem.exists("f.txt"));
}

test "opening a link as a directory without following it is not a directory" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try filesystem.makeSymlink("dir", "dirlink");
    try testing.expectError(error.NotDir, Dir.cwd().openDir(world.io, "dirlink", .{ .follow_symlinks = false }));
    var followed = try Dir.cwd().openDir(world.io, "dirlink", .{});
    followed.close(world.io);
    try testing.expectError(error.SymLinkLoop, Dir.cwd().openFile(world.io, "link", .{ .follow_symlinks = false }));
}

test "a link to a directory is walked through but not into when listed" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try filesystem.makeSymlink("dir", "dirlink");
    var dir = try Dir.cwd().openDir(world.io, "dirlink", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(world.io)) |_| {
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "a hard link gives a file a second name and a count of two" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.hardLink("f.txt", cwd, "second.txt", world.io, .{});
    try testing.expectEqual(@as(@TypeOf((try cwd.statFile(world.io, "f.txt", .{})).nlink), 2), (try cwd.statFile(world.io, "f.txt", .{})).nlink);
    try cwd.writeFile(world.io, .{ .sub_path = "second.txt", .data = "shared" });
    const read = try readAll(&world, "f.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("shared", read);

    // Removing one name leaves the other.
    try cwd.deleteFile(world.io, "f.txt");
    try testing.expect(filesystem.exists("second.txt"));
    try testing.expectError(error.PathAlreadyExists, cwd.hardLink("second.txt", cwd, "dir/a.txt", world.io, .{}));
    try testing.expectError(error.PermissionDenied, cwd.hardLink("dir", cwd, "dirname", world.io, .{}));
}

test "a hard link from an open file gives it a second name" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try file.hardLink(world.io, Dir.cwd(), "named.txt", .{});
    try testing.expect(filesystem.exists("named.txt"));
}

// The calls the code under test makes that are built on others.

test "deleteTree removes a nested directory, links included and leaves what a link pointed at" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try filesystem.makeFile("tree/one/two/deep.txt", "deep");
    try filesystem.makeFile("tree/top.txt", "top");
    try filesystem.makeSymlink("/f.txt", "tree/pointer");
    try filesystem.makeSymlink("/dir", "tree/dirpointer");
    try Dir.cwd().deleteTree(world.io, "tree");
    try testing.expect(!filesystem.exists("tree"));
    try testing.expect(filesystem.exists("f.txt"));
    try testing.expect(filesystem.exists("dir/a.txt"));
}

test "deleteTree of a missing path, a file and a link succeeds" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.deleteTree(world.io, "nowhere");
    try cwd.deleteTree(world.io, "f.txt");
    try cwd.deleteTree(world.io, "link");
    try testing.expect(!filesystem.exists("f.txt"));
    try testing.expect(filesystem.kindOf("link") == null);
}

test "deleteTree removes a tree deeper than its own stack" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(testing.allocator);
    try path.appendSlice(testing.allocator, "deep");
    for (0..30) |_| {
        try path.appendSlice(testing.allocator, "/d");
    }
    const leaf = try std.fmt.allocPrint(testing.allocator, "{s}/leaf.txt", .{path.items});
    defer testing.allocator.free(leaf);
    try filesystem.makeFile(leaf, "x");
    try Dir.cwd().deleteTree(world.io, "deep");
    try testing.expect(!filesystem.exists("deep"));
}

test "walk visits every entry below a directory with the path from it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeFile("commands/b.md", "b");
    try filesystem.makeFile("commands/a/inner.md", "inner");
    try filesystem.makeFile("commands/a/z.txt", "z");
    var dir = try Dir.cwd().openDir(world.io, "commands", .{ .iterate = true });
    defer dir.close(world.io);
    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    while (try walker.next(world.io)) |entry| {
        try seen.print(testing.allocator, "{s}:{s};", .{ entry.path, @tagName(entry.kind) });
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".md")) {
            const text = try entry.dir.readFileAlloc(world.io, entry.basename, testing.allocator, .limited(100));
            defer testing.allocator.free(text);
            try seen.print(testing.allocator, "{s};", .{text});
        }
    }
    try testing.expectEqualStrings("a:directory;a/inner.md:file;inner;a/z.txt:file;b.md:file;b;", seen.items);
}

test "realPath of an open directory is its absolute path and a link is resolved" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.makeFile("/tmp/skilled-test-1/inner/file.txt", "x");
    try filesystem.makeSymlink("/tmp/skilled-test-1", "/alias");
    var dir = try Dir.cwd().openDir(world.io, "/tmp/skilled-test-1", .{});
    defer dir.close(world.io);
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(world.io, &buffer);
    try testing.expectEqualStrings("/tmp/skilled-test-1", buffer[0..length]);

    var through = try Dir.cwd().openDir(world.io, "/alias", .{});
    defer through.close(world.io);
    const through_length = try through.realPath(world.io, &buffer);
    try testing.expectEqualStrings("/tmp/skilled-test-1", buffer[0..through_length]);

    const file_length = try dir.realPathFile(world.io, "inner/file.txt", &buffer);
    try testing.expectEqualStrings("/tmp/skilled-test-1/inner/file.txt", buffer[0..file_length]);
    try testing.expectError(error.FileNotFound, dir.realPathFile(world.io, "nowhere", &buffer));
    var tiny: [3]u8 = undefined;
    try testing.expectError(error.NameTooLong, dir.realPath(world.io, &tiny));

    var file = try dir.openFile(world.io, "inner/file.txt", .{});
    defer file.close(world.io);
    const open_length = try file.realPath(world.io, &buffer);
    try testing.expectEqualStrings("/tmp/skilled-test-1/inner/file.txt", buffer[0..open_length]);
}

test "an atomic write puts a file in place only when it is replaced" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    var atomic = try cwd.createFileAtomic(world.io, "dir/target.txt", .{ .replace = true });
    defer atomic.deinit(world.io);
    try atomic.file.writePositionalAll(world.io, "atomic contents", 0);
    try testing.expect(!filesystem.exists("dir/target.txt"));
    try atomic.replace(world.io);
    const read = try readAll(&world, "dir/target.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("atomic contents", read);

    // The temporary name does not stay behind.
    const names = try filesystem.listDirectory(testing.allocator, "dir");
    defer filesystem.freeNames(testing.allocator, names);
    try testing.expectEqual(@as(usize, 4), names.len);
}

test "an atomic write that is dropped leaves no temporary file" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var atomic = try Dir.cwd().createFileAtomic(world.io, "dir/never.txt", .{});
    atomic.deinit(world.io);
    const names = try filesystem.listDirectory(testing.allocator, "dir");
    defer filesystem.freeNames(testing.allocator, names);
    try testing.expectEqual(@as(usize, 3), names.len);
}

test "an atomic link refuses to replace a name that is taken" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var atomic = try Dir.cwd().createFileAtomic(world.io, "f.txt", .{});
    defer atomic.deinit(world.io);
    try testing.expectError(error.PathAlreadyExists, atomic.link(world.io));
}

test "an atomic write can make the directories above it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var atomic = try Dir.cwd().createFileAtomic(world.io, "made/on/the/way.txt", .{ .make_path = true, .replace = true });
    defer atomic.deinit(world.io);
    try atomic.replace(world.io);
    try testing.expect(filesystem.exists("made/on/the/way.txt"));
}

test "copyFile copies a file larger than one chunk and keeps the source" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var big: [10000]u8 = undefined;
    for (&big, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    try filesystem.makeFile("source.bin", &big);
    const cwd = Dir.cwd();
    try cwd.copyFile("source.bin", cwd, "copy.bin", world.io, .{});
    const read = try filesystem.readContents(testing.allocator, "copy.bin");
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, &big, read);
    try testing.expect(filesystem.exists("source.bin"));
    const names = try filesystem.listDirectory(testing.allocator, ".");
    defer filesystem.freeNames(testing.allocator, names);
    try testing.expectEqual(@as(usize, 2), names.len);
}

test "copyFile replaces an existing file or refuses when told not to" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    const cwd = Dir.cwd();
    try cwd.copyFile("f.txt", cwd, "dir/a.txt", world.io, .{});
    try testing.expectEqual(@as(u64, 10), (try cwd.statFile(world.io, "dir/a.txt", .{})).size);
    try testing.expectError(error.PathAlreadyExists, cwd.copyFile("f.txt", cwd, "dir/b.txt", world.io, .{ .replace = false }));
}

test "copyFile of a missing source is not found" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const cwd = Dir.cwd();
    try testing.expectError(error.FileNotFound, cwd.copyFile("nowhere", cwd, "x", world.io, .{}));
}

test "a stream writer copies a reader into a file in streaming mode" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var big: [9000]u8 = undefined;
    for (&big, 0..) |*byte, index| {
        byte.* = @intCast(index % 200);
    }
    try filesystem.makeFile("source.bin", &big);
    var source = try Dir.cwd().openFile(world.io, "source.bin", .{});
    defer source.close(world.io);
    var destination = try Dir.cwd().createFile(world.io, "dest.bin", .{});
    defer destination.close(world.io);

    var reader = source.reader(world.io, &.{});
    var buffer: [64]u8 = undefined;
    var writer = destination.writerStreaming(world.io, &buffer);
    const moved = try writer.interface.sendFileAll(&reader, .unlimited);
    try writer.interface.flush();
    try testing.expectEqual(@as(usize, big.len), moved);
    const read = try filesystem.readContents(testing.allocator, "dest.bin");
    defer testing.allocator.free(read);
    try testing.expectEqualSlices(u8, &big, read);
}

test "a stream writer copies a reader to standard output" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var source = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer source.close(world.io);
    var reader = source.reader(world.io, &.{});
    var buffer: [8]u8 = undefined;
    var writer = File.stdout().writerStreaming(world.io, &buffer);
    _ = try writer.interface.sendFileAll(&reader, .unlimited);
    try writer.interface.flush();
    try testing.expectEqualStrings("0123456789", filesystem.standardOutput());
}

test "a sync of an open file succeeds" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .read_write });
    defer file.close(world.io);
    try file.sync(world.io);
}

// The operations skilled uses, run in the order its link and package code runs them.

test "the filesystem calls skilled makes all work together" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    const cwd = Dir.cwd();

    // The temporary directory helper: make a directory, open it and ask for its real path.
    try cwd.createDirPath(world.io, "/tmp/skilled-test-0001");
    var temporary = try cwd.openDir(world.io, "/tmp/skilled-test-0001", .{});
    var real: [Dir.max_path_bytes]u8 = undefined;
    const real_length = try temporary.realPath(world.io, &real);
    temporary.close(world.io);
    const root = real[0..real_length];

    // A package with skills and commands, read the way the scanner reads them.
    var path_buffer: [256]u8 = undefined;
    for ([_][]const u8{ "skills/loc/SKILL.md", "commands/deep/run.md", "commands/top.md" }) |name| {
        const full = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, name });
        try cwd.createDirPath(world.io, std.fs.path.dirname(full).?);
        try cwd.writeFile(world.io, .{ .sub_path = full, .data = name });
    }
    const skills_path = try std.fmt.allocPrint(testing.allocator, "{s}/skills", .{root});
    defer testing.allocator.free(skills_path);
    var skills = try cwd.openDir(world.io, skills_path, .{ .iterate = true });
    defer skills.close(world.io);
    var iterator = skills.iterate();
    const entry = (try iterator.next(world.io)).?;
    try testing.expectEqualStrings("loc", entry.name);
    try testing.expect(entry.kind == .directory);
    try testing.expect((try iterator.next(world.io)) == null);

    const commands_path = try std.fmt.allocPrint(testing.allocator, "{s}/commands", .{root});
    defer testing.allocator.free(commands_path);
    var commands = try cwd.openDir(world.io, commands_path, .{ .iterate = true });
    defer commands.close(world.io);
    var walker = try commands.walk(testing.allocator);
    defer walker.deinit();
    var md_files: usize = 0;
    while (try walker.next(world.io)) |walked| {
        if (walked.kind == .directory or !std.mem.endsWith(u8, walked.basename, ".md")) {
            continue;
        }
        const text = try walked.dir.readFileAlloc(world.io, walked.basename, testing.allocator, .limited(1024));
        defer testing.allocator.free(text);
        md_files += 1;
    }
    try testing.expectEqual(@as(usize, 2), md_files);

    // The linker: stat without following, create a link, read it back, replace it, remove it.
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/agent/loc", .{root});
    defer testing.allocator.free(link_path);
    try cwd.createDirPath(world.io, std.fs.path.dirname(link_path).?);
    try testing.expectError(error.FileNotFound, cwd.statFile(world.io, link_path, .{ .follow_symlinks = false }));
    try cwd.symLink(world.io, skills_path, link_path, .{ .is_directory = true });
    const seen = try cwd.statFile(world.io, link_path, .{ .follow_symlinks = false });
    try testing.expectEqual(File.Kind.sym_link, seen.kind);
    try testing.expectEqual(File.Kind.directory, (try cwd.statFile(world.io, link_path, .{ .follow_symlinks = true })).kind);
    var target: [Dir.max_path_bytes]u8 = undefined;
    const target_length = try cwd.readLink(world.io, link_path, &target);
    try testing.expectEqualStrings(skills_path, target[0..target_length]);
    try cwd.deleteFile(world.io, link_path);
    try cwd.symLink(world.io, commands_path, link_path, .{ .is_directory = true });
    try testing.expectError(error.IsDir, cwd.deleteFile(world.io, commands_path));
    try cwd.deleteFile(world.io, link_path);

    // Cleaning up the temporary directory.
    try cwd.deleteTree(world.io, root);
    try testing.expect(!filesystem.exists(root));
}

// Locks.

test "a lock taken with a second handle is refused by tryLock and given back by unlock" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var first = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer first.close(world.io);
    var second = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer second.close(world.io);
    try first.lock(world.io, .exclusive);
    try testing.expect(!try second.tryLock(world.io, .shared));
    first.unlock(world.io);
    try testing.expect(try second.tryLock(world.io, .shared));

    // Two shared locks do not conflict and an exclusive one does.
    try testing.expect(try first.tryLock(world.io, .shared));
    second.unlock(world.io);
    try testing.expect(!try second.tryLock(world.io, .exclusive));
    try first.downgradeLock(world.io);
}

test "a file opened with a non-blocking lock that is held says it would block" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var first = try Dir.cwd().openFile(world.io, "f.txt", .{ .lock = .exclusive });
    defer first.close(world.io);
    try testing.expectError(error.WouldBlock, Dir.cwd().openFile(world.io, "f.txt", .{ .lock = .shared, .lock_nonblocking = true }));
    var again = try Dir.cwd().openFile(world.io, "f.txt", .{ .lock = .shared });
    again.close(world.io);
}

test "closing a file releases its lock" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var first = try Dir.cwd().openFile(world.io, "f.txt", .{ .lock = .exclusive });
    first.close(world.io);
    var second = try Dir.cwd().openFile(world.io, "f.txt", .{ .lock = .exclusive, .lock_nonblocking = true });
    second.close(world.io);
}

// Standard input, output and error.

test "standard output and standard error are captured in memory and kept apart" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var out_buffer: [16]u8 = undefined;
    var out = File.stdout().writer(world.io, &out_buffer);
    try out.interface.writeAll("to out\n");
    try out.interface.flush();
    var err_buffer: [16]u8 = undefined;
    var err = File.stderr().writer(world.io, &err_buffer);
    try err.interface.print("to err {d}\n", .{7});
    try err.interface.flush();

    try testing.expectEqualStrings("to out\n", filesystem.standardOutput());
    try testing.expectEqualStrings("to err 7\n", filesystem.standardError());
}

test "standard input reads what a scenario set and then ends" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    try filesystem.setStandardInput("first line\nsecond\n");
    var buffer: [32]u8 = undefined;
    var reader = File.stdin().reader(world.io, &buffer);
    try testing.expectEqualStrings("first line", try reader.interface.takeDelimiterExclusive('\n'));
    reader.interface.toss(1);
    try testing.expectEqualStrings("second", try reader.interface.takeDelimiterExclusive('\n'));
    reader.interface.toss(1);
    try testing.expectError(error.EndOfStream, reader.interface.takeDelimiterExclusive('\n'));
}

test "empty standard input ends at once" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var buffer: [8]u8 = undefined;
    var reader = File.stdin().reader(world.io, &buffer);
    try testing.expectError(error.EndOfStream, reader.interface.takeByte());
}

test "the standard streams are not terminals and cannot be resized or seeked" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    for ([_]File{ File.stdin(), File.stdout(), File.stderr() }) |stream| {
        try testing.expect(!try stream.isTty(world.io));
        try testing.expect(!try stream.supportsAnsiEscapeCodes(world.io));
        try testing.expectError(error.NotTerminalDevice, stream.enableAnsiEscapeCodes(world.io));
        try testing.expectError(error.Unseekable, world.io.vtable.fileSeekTo(world.io.userdata, stream, 0));
        try testing.expectError(error.NonResizable, stream.setLength(world.io, 0));
        try testing.expectEqual(File.Kind.character_device, (try stream.stat(world.io)).kind);
        try testing.expectEqual(@as(u64, 0), try stream.length(world.io));
    }
}

test "an ordinary file is not a terminal either" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try testing.expect(!try file.isTty(world.io));
}

// The current directory.

test "the current directory starts at the root and relative paths follow it when it moves" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var buffer: [Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/", buffer[0..try std.process.currentPath(world.io, &buffer)]);
    try std.process.setCurrentPath(world.io, "dir");
    try testing.expectEqualStrings("/dir", buffer[0..try std.process.currentPath(world.io, &buffer)]);
    const read = try readAll(&world, "a.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("a", read);
    try testing.expectError(error.FileNotFound, readAll(&world, "f.txt"));

    var root = try Dir.cwd().openDir(world.io, "/", .{});
    defer root.close(world.io);
    try std.process.setCurrentDir(world.io, root);
    try testing.expectEqualStrings("/", buffer[0..try std.process.currentPath(world.io, &buffer)]);
}

test "setting the current directory to something that is not a directory is refused" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try testing.expectError(error.FileNotFound, std.process.setCurrentPath(world.io, "nowhere"));
    try testing.expectError(error.NotDir, std.process.setCurrentPath(world.io, "f.txt"));
    try testing.expectError(error.AccessDenied, blk: {
        try filesystem.setMode("empty", 0o600);
        break :blk std.process.setCurrentPath(world.io, "empty");
    });
}

test "a current directory that was deleted has no path and finds nothing" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try std.process.setCurrentPath(world.io, "empty");
    try Dir.cwd().deleteDir(world.io, "/empty");
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    try testing.expectError(error.CurrentDirUnlinked, std.process.currentPath(world.io, &buffer));
    try testing.expectError(error.FileNotFound, readAll(&world, "anything"));

    // An absolute path still works.
    const read = try readAll(&world, "/f.txt");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("0123456789", read);
}

test "a path too long for the buffer is refused by currentPath" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try std.process.setCurrentPath(world.io, "dir");
    var tiny: [2]u8 = undefined;
    try testing.expectError(error.NameTooLong, std.process.currentPath(world.io, &tiny));
}

// Handles.

test "a handle from this filesystem is far above any real descriptor and is closed for good" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    try testing.expect(file.handle >= filesystem.first_handle);
    try testing.expect(filesystem.isSimulatedFileHandle(file.handle));
    try testing.expect(!filesystem.isSimulatedFileHandle(7));
    try testing.expect(!filesystem.isSimulatedDirHandle(7));
    file.close(world.io);

    // A closed handle is not found and is not passed to a real descriptor of the same number.
    try testing.expectError(error.Unexpected, file.length(world.io));
    var one: [1]u8 = undefined;
    try testing.expectError(error.NotOpenForReading, file.readStreaming(world.io, &.{&one}));
}

test "a handle in the simulated range that was never given out is refused and not passed on" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    const made_up: File = .{ .handle = filesystem.first_handle + 12345, .flags = .{ .nonblocking = false } };
    try testing.expectError(error.Unexpected, made_up.length(world.io));
    const made_up_dir: Dir = .{ .handle = filesystem.first_handle + 12345 };
    try testing.expectError(error.FileNotFound, made_up_dir.statFile(world.io, "x", .{}));
}

// What a handle that is not the filesystem's own is sent to: the `Io` underneath.
fn answerFromUnderneath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.StatFileOptions,
) Dir.StatFileError!File.Stat {
    _ = userdata;
    _ = dir;
    _ = sub_path;
    _ = options;
    return error.NetworkNotFound;
}

test "a handle that is not simulated goes to the Io underneath and a simulated one does not" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var underneath_room = threaded.io().vtable.*;
    underneath_room.dirStatFile = answerFromUnderneath;
    const underneath: std.Io = .{ .userdata = threaded.io().userdata, .vtable = &underneath_room };
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    var room: std.Io.VTable = undefined;
    filesystem.reset();
    defer filesystem.reset();
    const io = filesystem.install(underneath, &room, &injector);

    const real_looking: Dir = .{ .handle = 9 };
    try testing.expectError(error.NetworkNotFound, real_looking.statFile(io, "x", .{}));
    try testing.expectError(error.FileNotFound, Dir.cwd().statFile(io, "x", .{}));
}

// An entry another install overrides, so a test can tell it survived: it fills the buffer with a
// recognisable byte.
fn markedRandom(userdata: ?*anyopaque, buffer: []u8) void {
    _ = userdata;
    @memset(buffer, 0xAB);
}

test "the filesystem keeps an override an earlier install made and a later install keeps the filesystem" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    filesystem.reset();
    defer filesystem.reset();

    // The other install first, the filesystem second.
    var other_room = threaded.io().vtable.*;
    other_room.random = markedRandom;
    const other_first: std.Io = .{ .userdata = threaded.io().userdata, .vtable = &other_room };
    var room_a: std.Io.VTable = undefined;
    const io_a = filesystem.install(other_first, &room_a, &injector);
    var marked: [4]u8 = undefined;
    io_a.random(&marked);
    try testing.expectEqualSlices(u8, &[_]u8{0xAB} ** 4, &marked);
    try Dir.cwd().writeFile(io_a, .{ .sub_path = "chain.txt", .data = "a" });

    // The filesystem first, the other install second, which copies the filesystem's vtable.
    var room_b: std.Io.VTable = undefined;
    const io_b = filesystem.install(threaded.io(), &room_b, &injector);
    var room_c = io_b.vtable.*;
    room_c.random = markedRandom;
    const io_c: std.Io = .{ .userdata = io_b.userdata, .vtable = &room_c };
    io_c.random(&marked);
    try testing.expectEqualSlices(u8, &[_]u8{0xAB} ** 4, &marked);
    const read = try Dir.cwd().readFileAlloc(io_c, "chain.txt", testing.allocator, .unlimited);
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("a", read);
}

test "memory maps and the program's own executable are not in the simulated tree" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try testing.expectError(error.AccessDenied, file.createMemoryMap(world.io, .{ .len = 4 }));
    try testing.expectError(error.FileNotFound, std.process.openExecutable(world.io, .{}));
}

// The helpers a scenario uses.

test "the helpers build and inspect the tree without a world installed" {
    filesystem.reset();
    defer filesystem.reset();

    try filesystem.makeFile("a/b/c.txt", "hello");
    try filesystem.makeDirectory("a/empty");
    try filesystem.makeSymlink("b/c.txt", "a/pointer");
    try testing.expect(filesystem.exists("a/pointer"));
    try testing.expect(!filesystem.exists("a/nowhere"));
    try testing.expectEqual(File.Kind.sym_link, filesystem.kindOf("a/pointer").?);
    try testing.expectEqual(File.Kind.directory, filesystem.kindOf("a/empty").?);
    try testing.expect(filesystem.kindOf("a/nowhere") == null);
    try testing.expectEqualStrings("b/c.txt", filesystem.readSymlink("a/pointer").?);
    try testing.expect(filesystem.readSymlink("a/b/c.txt") == null);

    const text = try filesystem.readContents(testing.allocator, "a/pointer");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("hello", text);
    const names = try filesystem.listDirectory(testing.allocator, "a");
    defer filesystem.freeNames(testing.allocator, names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("b", names[0]);
    try testing.expectEqualStrings("empty", names[1]);
    try testing.expectEqualStrings("pointer", names[2]);

    try testing.expectError(error.IsDir, filesystem.readContents(testing.allocator, "a"));
    try testing.expectError(error.NotDir, filesystem.listDirectory(testing.allocator, "a/b/c.txt"));
    try testing.expectError(error.FileNotFound, filesystem.readContents(testing.allocator, "nowhere"));
    try testing.expectError(error.PathAlreadyExists, filesystem.makeSymlink("x", "a/pointer"));
    try testing.expectError(error.IsDir, filesystem.makeFile("a", "x"));
    try testing.expectError(error.FileNotFound, filesystem.setMode("nowhere", 0o600));
    try testing.expectError(error.FileNotFound, filesystem.setModifiedTime("nowhere", .{ .nanoseconds = 0 }));
}

test "the helper that sets a modified time is what stat reports" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try filesystem.setModifiedTime("f.txt", .{ .nanoseconds = 42 });
    try testing.expectEqual(@as(i96, 42), (try Dir.cwd().statFile(world.io, "f.txt", .{})).mtime.nanoseconds);
}

test "making a file replaces what was there" {
    filesystem.reset();
    defer filesystem.reset();

    try filesystem.makeFile("same", "one");
    try filesystem.makeFile("same", "two");
    const text = try filesystem.readContents(testing.allocator, "same");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("two", text);
}

// Failures, one group of rows of `docs/FAILURES.md` at a time.

// The operations the tests below inject failures into.

fn openForRead(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    file.close(world.io);
}

fn openForWrite(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .write_only });
    file.close(world.io);
}

fn createNew(world: *World) anyerror!void {
    var file = try Dir.cwd().createFile(world.io, "new.txt", .{});
    file.close(world.io);
}

fn createExclusive(world: *World) anyerror!void {
    var file = try Dir.cwd().createFile(world.io, "new.txt", .{ .exclusive = true });
    file.close(world.io);
}

fn checkAccess(world: *World) anyerror!void {
    try Dir.cwd().access(world.io, "f.txt", .{});
}

fn checkStat(world: *World) anyerror!void {
    _ = try Dir.cwd().statFile(world.io, "f.txt", .{});
}

test "file open rows: each failure of an open is what the table says" {
    try expectEveryCase(.file_open, &.{
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = openForRead },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = openForRead },
        .{ .id = "is_a_directory", .expected = error.IsDir, .run = openForRead },
        .{ .id = "not_a_directory", .expected = error.NotDir, .run = openForRead },
        .{ .id = "name_too_long", .expected = error.NameTooLong, .run = openForRead },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = openForRead },
        .{ .id = "too_many_open_files", .expected = error.ProcessFdQuotaExceeded, .run = openForRead },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = openForWrite },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = createNew },
        .{ .id = "already_exists", .expected = error.PathAlreadyExists, .run = createExclusive },
    });
}

test "file open rows: a check of a name can fail with the rows its error set has" {
    try expectEveryCase(.file_open, &.{
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = checkAccess },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = checkAccess },
        .{ .id = "name_too_long", .expected = error.NameTooLong, .run = checkAccess },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = checkAccess },
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = checkStat },
        .{ .id = "not_a_directory", .expected = error.NotDir, .run = checkStat },
        .{ .id = "too_many_open_files", .expected = error.ProcessFdQuotaExceeded, .run = checkStat },
    });
}

test "an open does not fail with a row that cannot happen to it" {
    // Exclusive creation is the only create that can find the name taken and a plain open cannot
    // run out of space, so planning those for an open does nothing.
    const plan = [_]injector_mod.Injection{at(.file_open, 0, "already_exists")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();
    try openForRead(&world);
    try createNew(&world);
}

test "an open asks once and records the rows that can happen to it" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try openForRead(&world);
    try testing.expectEqual(@as(usize, 1), world.injector.recorded.items.len);
    const place = world.injector.recorded.items[0];
    try testing.expectEqual(point.Effect.file_open, place.point.effect);
    const kinds = failures.kindsOf(.file_open);
    for (place.kinds) |index| {
        try testing.expect(!std.mem.eql(u8, kinds[index].id, "already_exists"));
        try testing.expect(!std.mem.eql(u8, kinds[index].id, "read_only_filesystem"));
    }
    try testing.expect(place.kinds.len > 0);
}

test "only the planned call fails and the next one goes ahead" {
    const plan = [_]injector_mod.Injection{at(.file_open, 0, "file_not_found")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();
    try testing.expectError(error.FileNotFound, openForRead(&world));
    try openForRead(&world);
}

// A read of the ten bytes of `f.txt`, into a buffer of `capacity` bytes, at the start.
fn readPositionalOnce(world: *World, capacity: usize, out: []u8) !usize {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    return file.readPositional(world.io, &.{out[0..capacity]}, 0);
}

fn positionalRead(world: *World) anyerror!void {
    var buffer: [8]u8 = undefined;
    _ = try readPositionalOnce(world, 8, &buffer);
}

fn streamingRead(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [8]u8 = undefined;
    _ = try file.readStreaming(world.io, &.{&buffer});
}

fn directoryRead(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "dir", .{});
    defer file.close(world.io);
    var buffer: [8]u8 = undefined;
    _ = try file.readPositional(world.io, &.{&buffer}, 0);
}

test "read rows: an input error and a read of a directory" {
    try expectEveryCase(.read, &.{
        .{ .id = "input_or_output_error", .expected = error.InputOutput, .run = positionalRead },
        .{ .id = "input_or_output_error", .expected = error.InputOutput, .run = streamingRead },
        .{ .id = "read_of_a_directory", .expected = error.IsDir, .run = positionalRead },
        .{ .id = "read_of_a_directory", .expected = error.IsDir, .run = streamingRead },
    });
}

test "a read of a real directory is refused as a directory" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();
    try testing.expectError(error.IsDir, directoryRead(&world));
}

test "read rows: a short read gives fewer bytes now and the rest on the next read" {
    const plan = [_]injector_mod.Injection{at(.read, 0, "short_read")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [8]u8 = undefined;
    const first = try file.readPositional(world.io, &.{&buffer}, 0);
    try testing.expect(first > 0 and first < 8);
    try testing.expectEqualStrings("0123456789"[0..first], buffer[0..first]);

    // The next read, with nothing injected, gives the rest of what was asked for.
    const second = try file.readPositional(world.io, &.{buffer[first..]}, first);
    try testing.expectEqual(@as(usize, 8) - first, second);
    try testing.expectEqualStrings("01234567", &buffer);
}

test "read rows: a stream reader still reads everything through a short read" {
    const plan = [_]injector_mod.Injection{at(.read, 0, "short_read")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [4]u8 = undefined;
    var reader = file.reader(world.io, &buffer);
    var out: [10]u8 = undefined;
    try reader.interface.readSliceAll(&out);
    try testing.expectEqualStrings("0123456789", &out);
}

test "read rows: a streaming short read gives fewer bytes and then the rest" {
    const plan = [_]injector_mod.Injection{at(.read, 0, "short_read")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [10]u8 = undefined;
    const first = try file.readStreaming(world.io, &.{&buffer});
    try testing.expect(first > 0 and first < 10);
    const second = try file.readStreaming(world.io, &.{buffer[first..]});
    try testing.expectEqual(@as(usize, 10) - first, second);
    try testing.expectEqualStrings("0123456789", &buffer);
}

test "read rows: an early end of stream ends the read before the expected length" {
    const plan = [_]injector_mod.Injection{at(.read, 0, "early_end_of_stream")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [4]u8 = undefined;
    var reader = file.reader(world.io, &buffer);
    var out: [10]u8 = undefined;

    // The file holds ten bytes and the caller expects ten and the stream ends first.
    try testing.expectError(error.EndOfStream, reader.interface.readSliceAll(&out));
}

test "read rows: an early end of stream on a streaming read" {
    const plan = [_]injector_mod.Injection{at(.read, 0, "early_end_of_stream")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.EndOfStream, file.readStreaming(world.io, &.{&buffer}));
}

// Whether the places an injector recorded for `effect` offered the row `id` anywhere.
fn wasOffered(world: *World, effect: point.Effect, id: []const u8) bool {
    for (world.injector.recorded.items) |place| {
        if (place.point.effect != effect) {
            continue;
        }
        for (place.kinds) |index| {
            if (std.mem.eql(u8, failures.kindsOf(effect)[index].id, id)) {
                return true;
            }
        }
    }
    return false;
}

test "a short read is offered for ten bytes and not for one and an early end is not offered at the end" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var buffer: [10]u8 = undefined;
    _ = try readPositionalOnce(&world, 10, &buffer);
    try testing.expect(wasOffered(&world, .read, "short_read"));
    try testing.expect(wasOffered(&world, .read, "early_end_of_stream"));

    world.injector.reset();
    _ = try readPositionalOnce(&world, 1, &buffer);
    try testing.expect(!wasOffered(&world, .read, "short_read"));
    try testing.expect(wasOffered(&world, .read, "early_end_of_stream"));

    world.injector.reset();
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    _ = try file.readPositional(world.io, &.{&buffer}, 10);
    try testing.expect(!wasOffered(&world, .read, "early_end_of_stream"));
    try testing.expect(!wasOffered(&world, .read, "short_read"));
    try testing.expect(wasOffered(&world, .read, "input_or_output_error"));
}

// A write of `data` at the start of a new file.
fn positionalWrite(world: *World) anyerror!void {
    var file = try Dir.cwd().createFile(world.io, "out.bin", .{});
    defer file.close(world.io);
    try file.writePositionalAll(world.io, "12345678", 0);
}

fn streamingWrite(world: *World) anyerror!void {
    var file = try Dir.cwd().createFile(world.io, "out.bin", .{});
    defer file.close(world.io);
    try file.writeStreamingAll(world.io, "12345678");
}

test "write rows: each failure of a write is what the table says" {
    try expectEveryCase(.write, &.{
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = positionalWrite },
        .{ .id = "input_or_output_error", .expected = error.InputOutput, .run = positionalWrite },
        .{ .id = "quota_exceeded", .expected = error.DiskQuota, .run = positionalWrite },
        .{ .id = "read_only_filesystem", .expected = error.AccessDenied, .run = positionalWrite },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = streamingWrite },
        .{ .id = "input_or_output_error", .expected = error.InputOutput, .run = streamingWrite },
        .{ .id = "quota_exceeded", .expected = error.DiskQuota, .run = streamingWrite },
        .{ .id = "read_only_filesystem", .expected = error.AccessDenied, .run = streamingWrite },
    });
}

test "write rows: a short write accepts fewer bytes and the rest goes on the next write" {
    const plan = [_]injector_mod.Injection{at(.write, 0, "short_write")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    var file = try Dir.cwd().createFile(world.io, "out.bin", .{});
    defer file.close(world.io);
    const first = try file.writePositional(world.io, &.{"12345678"}, 0);
    try testing.expect(first > 0 and first < 8);
    const second = try file.writePositional(world.io, &.{"12345678"[first..]}, first);
    try testing.expectEqual(@as(usize, 8) - first, second);
    const read = try filesystem.readContents(testing.allocator, "out.bin");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("12345678", read);
}

test "write rows: a short streaming write is finished by the caller's loop" {
    const plan = [_]injector_mod.Injection{at(.write, 0, "short_write")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    var file = try Dir.cwd().createFile(world.io, "out.bin", .{});
    defer file.close(world.io);
    const first = try file.writeStreaming(world.io, &.{}, &.{"12345678"}, 1);
    try testing.expect(first > 0 and first < 8);
    try file.writeStreamingAll(world.io, "12345678"[first..]);
    const read = try filesystem.readContents(testing.allocator, "out.bin");
    defer testing.allocator.free(read);
    try testing.expectEqualStrings("12345678", read);
}

test "a short write is not offered for a write of one byte" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();

    var file = try Dir.cwd().createFile(world.io, "one.bin", .{});
    defer file.close(world.io);
    _ = try file.writePositional(world.io, &.{"x"}, 0);
    for (world.injector.recorded.items) |place| {
        if (place.point.effect != .write) {
            continue;
        }
        for (place.kinds) |index| {
            try testing.expect(!std.mem.eql(u8, failures.kindsOf(.write)[index].id, "short_write"));
        }
    }
}

// Symlink and link operations.

fn makeLinkOver(world: *World) anyerror!void {
    try Dir.cwd().symLink(world.io, "f.txt", "link", .{});
}

fn makeLinkNew(world: *World) anyerror!void {
    try Dir.cwd().symLink(world.io, "f.txt", "fresh", .{});
}

fn readALink(world: *World) anyerror!void {
    var buffer: [64]u8 = undefined;
    _ = try Dir.cwd().readLink(world.io, "link", &buffer);
}

fn removeALink(world: *World) anyerror!void {
    try Dir.cwd().deleteFile(world.io, "link");
}

fn makeHardLink(world: *World) anyerror!void {
    try Dir.cwd().hardLink("f.txt", Dir.cwd(), "hard", world.io, .{});
}

test "link rows: making a link fails as the table says" {
    try expectEveryCase(.link, &.{
        .{ .id = "create_over_an_existing_path", .expected = error.PathAlreadyExists, .run = makeLinkNew },
        .{ .id = "create_without_permission", .expected = error.AccessDenied, .run = makeLinkNew },
        .{ .id = "create_in_a_missing_directory", .expected = error.FileNotFound, .run = makeLinkNew },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = makeLinkNew },
    });
}

test "link rows: reading a link fails as the table says" {
    try expectEveryCase(.link, &.{
        .{ .id = "read_a_link_that_is_not_a_link", .expected = error.NotLink, .run = readALink },
        .{ .id = "read_a_link_that_is_missing", .expected = error.FileNotFound, .run = readALink },
    });
}

test "link rows: removing a link that is missing" {
    try expectEveryCase(.link, &.{
        .{ .id = "remove_a_link_that_is_missing", .expected = error.FileNotFound, .run = removeALink },
    });
}

test "link rows: a hard link across filesystems and the other rows of a hard link" {
    try expectEveryCase(.link, &.{
        .{ .id = "hard_link_across_filesystems", .expected = error.CrossDevice, .run = makeHardLink },
        .{ .id = "create_over_an_existing_path", .expected = error.PathAlreadyExists, .run = makeHardLink },
        .{ .id = "create_without_permission", .expected = error.AccessDenied, .run = makeHardLink },
        .{ .id = "create_in_a_missing_directory", .expected = error.FileNotFound, .run = makeHardLink },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = makeHardLink },
    });
}

test "link rows: a real link made over an existing path, not injected, is refused" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();
    try testing.expectError(error.PathAlreadyExists, makeLinkOver(&world));
    try testing.expectError(error.NotLink, blk: {
        var buffer: [8]u8 = undefined;
        break :blk Dir.cwd().readLink(world.io, "f.txt", &buffer);
    });
}

test "link rows: a dangling link makes opening a link that is there return not found" {
    const plan = [_]injector_mod.Injection{at(.link, 0, "dangling_link")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    // The link and its target are both there. Following the link is what the failure breaks.
    try testing.expect(filesystem.exists("link"));
    try testing.expectError(error.FileNotFound, Dir.cwd().openFile(world.io, "link", .{}));
    var file = try Dir.cwd().openFile(world.io, "link", .{});
    file.close(world.io);
}

test "link rows: a link loop makes following a link that is fine return a loop error" {
    const plan = [_]injector_mod.Injection{at(.link, 0, "link_loop")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    try testing.expectError(error.SymLinkLoop, Dir.cwd().openFile(world.io, "link", .{}));
    var file = try Dir.cwd().openFile(world.io, "link", .{});
    file.close(world.io);
}

test "link rows: following a link asks once per link followed and a path without a link asks nothing" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();
    try filesystem.makeSymlink("link", "second");

    var file = try Dir.cwd().openFile(world.io, "second", .{});
    file.close(world.io);
    var link_asks: usize = 0;
    for (world.injector.recorded.items) |place| {
        if (place.point.effect == .link) {
            link_asks += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), link_asks);

    world.injector.reset();
    file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    file.close(world.io);
    for (world.injector.recorded.items) |place| {
        try testing.expect(place.point.effect != .link);
    }
}

// Directory listing.

fn openDirectory(world: *World) anyerror!void {
    var dir = try Dir.cwd().openDir(world.io, "dir", .{ .iterate = true });
    dir.close(world.io);
}

test "directory listing rows: opening a directory fails as the table says" {
    try expectEveryCase(.directory_listing, &.{
        .{ .id = "open_a_missing_directory", .expected = error.FileNotFound, .run = openDirectory },
        .{ .id = "open_a_file_as_a_directory", .expected = error.NotDir, .run = openDirectory },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = openDirectory },
        .{ .id = "too_many_open_files", .expected = error.ProcessFdQuotaExceeded, .run = openDirectory },
    });
}

test "directory listing rows: an error part way through gives some entries and then fails" {
    // Calls of this effect, counting from zero: the open is 0, the first read is 1 and the read
    // after one entry has been handed over is 2.
    const plan = [_]injector_mod.Injection{at(.directory_listing, 2, "error_part_way_through_the_listing")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, "dir", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    const first = (try iterator.next(world.io)).?;
    try testing.expectEqualStrings("a.txt", first.name);

    // The caller's own set has no word for an input error here, so it is what Zig itself reports.
    try testing.expectError(error.Unexpected, iterator.next(world.io));
}

test "directory listing rows: an empty directory is a listing with no entries" {
    const plan = [_]injector_mod.Injection{at(.directory_listing, 1, "empty_directory")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, "dir", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    try testing.expect((try iterator.next(world.io)) == null);
    try testing.expect((try iterator.next(world.io)) == null);
}

test "directory listing rows: access denied on the first read" {
    const plan = [_]injector_mod.Injection{at(.directory_listing, 1, "access_denied")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, "dir", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    try testing.expectError(error.AccessDenied, iterator.next(world.io));
}

test "directory listing rows: a part-way error is offered only after an entry has been returned" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    var dir = try Dir.cwd().openDir(world.io, "dir", .{ .iterate = true });
    defer dir.close(world.io);
    var iterator = dir.iterate();
    while (try iterator.next(world.io)) |_| {}
    const kinds = failures.kindsOf(.directory_listing);
    const places = world.injector.recorded.items;

    // The first read offers an empty listing and no part-way error, the reads in the middle offer
    // a part-way error and the last read, which only finds the end, offers neither.
    var has_part_way = [_]bool{false} ** 32;
    for (places[1..], 0..) |place, index| {
        for (place.kinds) |kind| {
            if (std.mem.eql(u8, kinds[kind].id, "error_part_way_through_the_listing")) {
                has_part_way[index] = true;
            }
        }
    }
    try testing.expect(!has_part_way[0]);
    try testing.expect(has_part_way[1]);
    try testing.expect(has_part_way[2]);
    try testing.expect(!has_part_way[3]);
}

// Delete.

fn deleteAFile(world: *World) anyerror!void {
    try Dir.cwd().deleteFile(world.io, "f.txt");
}

fn deleteAFileInADirectory(world: *World) anyerror!void {
    try Dir.cwd().deleteFile(world.io, "dir/a.txt");
}

fn deleteADirectory(world: *World) anyerror!void {
    try Dir.cwd().deleteDir(world.io, "empty");
}

test "delete rows: removing a file fails as the table says" {
    try expectEveryCase(.delete, &.{
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = deleteAFile },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = deleteAFile },
        .{ .id = "file_in_use", .expected = error.FileBusy, .run = deleteAFile },
        .{ .id = "is_a_directory", .expected = error.IsDir, .run = deleteAFile },
        .{ .id = "not_a_directory", .expected = error.NotDir, .run = deleteAFileInADirectory },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = deleteAFile },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = deleteAFile },
    });
}

test "delete rows: a file named with no / is never offered not a directory and one under a directory is" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try deleteAFile(&world);
    try testing.expect(!wasOffered(&world, .delete, "not_a_directory"));
    try testing.expect(wasOffered(&world, .delete, "file_not_found"));

    world.injector.reset();
    try deleteAFileInADirectory(&world);
    try testing.expect(wasOffered(&world, .delete, "not_a_directory"));
}

test "delete rows: removing a directory fails as the table says" {
    try expectEveryCase(.delete, &.{
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = deleteADirectory },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = deleteADirectory },
        .{ .id = "file_in_use", .expected = error.FileBusy, .run = deleteADirectory },
        .{ .id = "not_a_directory", .expected = error.NotDir, .run = deleteADirectory },
        .{ .id = "directory_not_empty", .expected = error.DirNotEmpty, .run = deleteADirectory },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = deleteADirectory },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = deleteADirectory },
    });
}

test "delete rows: an error part way through deleting a tree leaves the entries after it" {
    // The calls of this effect: deleteTree first tries the name as a file and is told it is a
    // directory (0), then removes a.txt (1), b.txt (2) and c.txt (3). The failure is at b.txt.
    const plan = [_]injector_mod.Injection{at(.delete, 2, "error_part_way_through_deleting_a_tree")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    try testing.expectError(error.FileSystem, Dir.cwd().deleteTree(world.io, "dir"));
    try testing.expect(!filesystem.exists("dir/a.txt"));
    try testing.expect(filesystem.exists("dir/b.txt"));
    try testing.expect(filesystem.exists("dir/c.txt"));

    // Running it again with nothing failing finishes the job.
    try Dir.cwd().deleteTree(world.io, "dir");
    try testing.expect(!filesystem.exists("dir"));
}

test "delete rows: a part-way error is not offered before anything has been removed" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try Dir.cwd().deleteTree(world.io, "dir");
    const kinds = failures.kindsOf(.delete);
    var offered_at: [32]bool = [_]bool{false} ** 32;
    var delete_calls: usize = 0;
    for (world.injector.recorded.items) |place| {
        if (place.point.effect != .delete) {
            continue;
        }
        for (place.kinds) |kind| {
            if (std.mem.eql(u8, kinds[kind].id, "error_part_way_through_deleting_a_tree")) {
                offered_at[delete_calls] = true;
            }
        }
        delete_calls += 1;
    }

    // The first call is the name tried as a file and the second removes the first entry. The
    // third has an earlier removal behind it.
    try testing.expect(!offered_at[0]);
    try testing.expect(!offered_at[1]);
    try testing.expect(offered_at[2]);
}

// Create a directory.

fn makeADirectory(world: *World) anyerror!void {
    try Dir.cwd().createDir(world.io, "made", .default_dir);
}

fn makeADirectoryPath(world: *World) anyerror!void {
    try Dir.cwd().createDirPath(world.io, "made/deeper");
}

test "create a directory rows: each failure is what the table says" {
    try expectEveryCase(.make_directory, &.{
        .{ .id = "already_exists", .expected = error.PathAlreadyExists, .run = makeADirectory },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = makeADirectory },
        .{ .id = "parent_directory_missing", .expected = error.FileNotFound, .run = makeADirectory },
        .{ .id = "parent_is_not_a_directory", .expected = error.NotDir, .run = makeADirectory },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = makeADirectory },
        .{ .id = "quota_exceeded", .expected = error.DiskQuota, .run = makeADirectory },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = makeADirectory },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = makeADirectoryPath },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = makeADirectoryPath },
        .{ .id = "quota_exceeded", .expected = error.DiskQuota, .run = makeADirectoryPath },
    });
}

// Resolve a path.

fn resolveAPath(world: *World) anyerror!void {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    _ = try Dir.cwd().realPathFile(world.io, "f.txt", &buffer);
}

test "resolve a path rows: each failure is what the table says" {
    try expectEveryCase(.resolve_path, &.{
        .{ .id = "path_not_found", .expected = error.FileNotFound, .run = resolveAPath },
        .{ .id = "not_a_directory", .expected = error.NotDir, .run = resolveAPath },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = resolveAPath },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = resolveAPath },
        .{ .id = "name_too_long", .expected = error.NameTooLong, .run = resolveAPath },
    });
}

fn resolveAnOpenDirectory(world: *World) anyerror!void {
    var dir = try Dir.cwd().openDir(world.io, "dir", .{});
    defer dir.close(world.io);
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    _ = try dir.realPath(world.io, &buffer);
}

fn resolveAnOpenFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    _ = try file.realPath(world.io, &buffer);
}

test "resolve a path rows: the same failures apply to an open directory and an open file" {
    try expectEveryCase(.resolve_path, &.{
        .{ .id = "path_not_found", .expected = error.FileNotFound, .run = resolveAnOpenDirectory },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = resolveAnOpenDirectory },
        .{ .id = "path_not_found", .expected = error.FileNotFound, .run = resolveAnOpenFile },
        .{ .id = "name_too_long", .expected = error.NameTooLong, .run = resolveAnOpenFile },
    });
}

// Standard input, output and error.

test "standard stream rows: input closed ends the first read and an input error fails it" {
    const closed = [_]injector_mod.Injection{at(.standard_stream, 0, "input_closed")};
    var world: World = undefined;
    world.create(&closed);
    defer world.destroy();

    try filesystem.setStandardInput("some input\n");
    var buffer: [16]u8 = undefined;
    var reader = File.stdin().reader(world.io, &buffer);
    try testing.expectError(error.EndOfStream, reader.interface.takeByte());
}

test "standard stream rows: an input error is a failed read with the error kept" {
    const plan = [_]injector_mod.Injection{at(.standard_stream, 0, "input_or_output_error")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    try filesystem.setStandardInput("some input\n");
    var buffer: [16]u8 = undefined;
    var reader = File.stdin().reader(world.io, &buffer);
    try testing.expectError(error.ReadFailed, reader.interface.takeByte());
    try testing.expectEqual(error.InputOutput, reader.err.?);
}

test "standard stream rows: an output that is closed fails the write" {
    const plan = [_]injector_mod.Injection{at(.standard_stream, 0, "output_closed")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    var buffer: [16]u8 = undefined;
    var writer = File.stdout().writer(world.io, &buffer);
    try writer.interface.writeAll("hello");
    try testing.expectError(error.WriteFailed, writer.interface.flush());
    try testing.expectEqual(error.BrokenPipe, writer.err.?);
    try testing.expectEqualStrings("", filesystem.standardOutput());
}

test "standard stream rows: an output error fails the write with the error kept" {
    const plan = [_]injector_mod.Injection{at(.standard_stream, 0, "input_or_output_error")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    var buffer: [16]u8 = undefined;
    var writer = File.stderr().writer(world.io, &buffer);
    try writer.interface.writeAll("hello");
    try testing.expectError(error.WriteFailed, writer.interface.flush());
    try testing.expectEqual(error.InputOutput, writer.err.?);
}

test "standard stream rows: a short write accepts fewer bytes and the writer finishes the rest" {
    const plan = [_]injector_mod.Injection{at(.standard_stream, 0, "short_write")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    const first = try File.stdout().writeStreaming(world.io, &.{}, &.{"12345678"}, 1);
    try testing.expect(first > 0 and first < 8);
    try File.stdout().writeStreamingAll(world.io, "12345678"[first..]);
    try testing.expectEqualStrings("12345678", filesystem.standardOutput());
}

test "standard stream rows: a writer carries on through a short write" {
    const plan = [_]injector_mod.Injection{at(.standard_stream, 0, "short_write")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    var buffer: [4]u8 = undefined;
    var writer = File.stdout().writer(world.io, &buffer);
    try writer.interface.writeAll("a longer message");
    try writer.interface.flush();
    try testing.expectEqualStrings("a longer message", filesystem.standardOutput());
}

// Rename and copy.

fn renameAFile(world: *World) anyerror!void {
    try Dir.cwd().rename("f.txt", Dir.cwd(), "renamed.txt", world.io);
}

fn renameWithoutReplacing(world: *World) anyerror!void {
    try Dir.cwd().renamePreserve("f.txt", Dir.cwd(), "renamed.txt", world.io);
}

test "rename rows: each failure of a rename is what the table says" {
    try expectEveryCase(.rename_copy, &.{
        .{ .id = "source_not_found", .expected = error.FileNotFound, .run = renameAFile },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = renameAFile },
        .{ .id = "destination_is_a_non_empty_directory", .expected = error.DirNotEmpty, .run = renameAFile },
        .{ .id = "destination_is_a_directory", .expected = error.IsDir, .run = renameAFile },
        .{ .id = "file_in_use", .expected = error.FileBusy, .run = renameAFile },
        .{ .id = "across_filesystems", .expected = error.CrossDevice, .run = renameAFile },
        .{ .id = "out_of_space", .expected = error.NoSpaceLeft, .run = renameAFile },
        .{ .id = "quota_exceeded", .expected = error.DiskQuota, .run = renameAFile },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = renameAFile },
        .{ .id = "source_not_found", .expected = error.FileNotFound, .run = renameWithoutReplacing },
        .{ .id = "across_filesystems", .expected = error.CrossDevice, .run = renameWithoutReplacing },
    });
}

test "rename rows: a failed rename leaves the file where it was" {
    const plan = [_]injector_mod.Injection{at(.rename_copy, 0, "across_filesystems")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    try testing.expectError(error.CrossDevice, renameAFile(&world));
    try testing.expect(filesystem.exists("f.txt"));
    try testing.expect(!filesystem.exists("renamed.txt"));
}

test "rename rows: copy fails part way through after some bytes were copied" {
    // A copy asks once per chunk it moves after the first, so a file of two chunks fails at the
    // second chunk, after the first has been written into the temporary file.
    const plan = [_]injector_mod.Injection{at(.rename_copy, 0, "copy_fails_part_way_through")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();

    var big: [6000]u8 = undefined;
    @memset(&big, 'z');
    try filesystem.makeFile("source.bin", &big);
    try testing.expectError(error.InputOutput, Dir.cwd().copyFile("source.bin", Dir.cwd(), "copy.bin", world.io, .{}));

    // The copy never reached its name and the temporary file was cleaned up.
    try testing.expect(!filesystem.exists("copy.bin"));
    const names = try filesystem.listDirectory(testing.allocator, ".");
    defer filesystem.freeNames(testing.allocator, names);
    try testing.expectEqual(@as(usize, 1), names.len);
}

test "rename rows: a copy of a file that fits in one chunk asks about the end of the copy" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try Dir.cwd().copyFile("f.txt", Dir.cwd(), "copied.txt", world.io, .{});
    var copy_places: usize = 0;
    for (world.injector.recorded.items) |place| {
        if (place.point.effect == .rename_copy) {
            copy_places += 1;
        }
    }

    // One ask for the call that finds the end and one for the rename that puts the copy in place.
    try testing.expectEqual(@as(usize, 2), copy_places);
}

// Change permissions, owner or timestamps.

fn changePermissions(world: *World) anyerror!void {
    try Dir.cwd().setFilePermissions(world.io, "f.txt", .default_file, .{});
}

fn changeOwner(world: *World) anyerror!void {
    try world.io.vtable.dirSetFileOwner(world.io.userdata, Dir.cwd(), "f.txt", 1, 1, .{});
}

fn changeTimes(world: *World) anyerror!void {
    try Dir.cwd().setTimestamps(world.io, "f.txt", .{ .modify_timestamp = .now });
}

fn changeTimesOfAFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try file.setTimestampsNow(world.io);
}

test "attribute rows: changing permissions fails as the table says" {
    try expectEveryCase(.attributes, &.{
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = changePermissions },
        .{ .id = "not_permitted", .expected = error.PermissionDenied, .run = changePermissions },
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = changePermissions },
        .{ .id = "input_or_output_error", .expected = error.InputOutput, .run = changePermissions },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = changePermissions },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = changePermissions },
    });
}

test "attribute rows: changing an owner fails as the table says" {
    try expectEveryCase(.attributes, &.{
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = changeOwner },
        .{ .id = "not_permitted", .expected = error.PermissionDenied, .run = changeOwner },
        .{ .id = "file_not_found", .expected = error.FileNotFound, .run = changeOwner },
        .{ .id = "input_or_output_error", .expected = error.InputOutput, .run = changeOwner },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = changeOwner },
        .{ .id = "symlink_loop", .expected = error.SymLinkLoop, .run = changeOwner },
    });
}

test "attribute rows: changing times fails with the rows its error set has" {
    try expectEveryCase(.attributes, &.{
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = changeTimes },
        .{ .id = "not_permitted", .expected = error.PermissionDenied, .run = changeTimes },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = changeTimes },
        .{ .id = "access_denied", .expected = error.AccessDenied, .run = changeTimesOfAFile },
        .{ .id = "not_permitted", .expected = error.PermissionDenied, .run = changeTimesOfAFile },
        .{ .id = "read_only_filesystem", .expected = error.ReadOnlyFileSystem, .run = changeTimesOfAFile },
    });
}

// File length, sync and locks.

fn readTheLength(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    _ = try file.length(world.io);
}

fn readTheStat(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    _ = try file.stat(world.io);
}

fn resizeAFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .read_write });
    defer file.close(world.io);
    try file.setLength(world.io, 3);
}

fn syncAFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{ .mode = .read_write });
    defer file.close(world.io);
    try file.sync(world.io);
}

fn lockAFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try file.lock(world.io, .exclusive);
}

fn tryLockAFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    if (!try file.tryLock(world.io, .exclusive)) {
        return error.LockWasHeld;
    }
}

fn seekAFile(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try world.io.vtable.fileSeekTo(world.io.userdata, file, 2);
}

fn seekAFileBy(world: *World) anyerror!void {
    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    try world.io.vtable.fileSeekBy(world.io.userdata, file, 2);
}

// The file state calls ask about the open too, so the row is looked for at the first call of the
// effect, which is the call under test because the open asks about a different effect.

test "file state rows: a length that cannot be read is what Zig reports for an input error" {
    // The error sets of `length` and `stat` have no input error and Zig's own implementation
    // reports one as `Unexpected`, so that is what the row returns here.
    try expectEveryCase(.file_state, &.{
        .{ .id = "length_cannot_be_read", .expected = error.Unexpected, .run = readTheLength },
        .{ .id = "length_cannot_be_read", .expected = error.Unexpected, .run = readTheStat },
    });
}

test "file state rows: a resize past the limit and a file that cannot be resized" {
    try expectEveryCase(.file_state, &.{
        .{ .id = "resize_past_the_size_limit", .expected = error.FileTooBig, .run = resizeAFile },
        .{ .id = "file_cannot_be_resized", .expected = error.NonResizable, .run = resizeAFile },
    });
}

test "file state rows: a sync that fails and a sync that finds the disk full" {
    try expectEveryCase(.file_state, &.{
        .{ .id = "sync_fails", .expected = error.InputOutput, .run = syncAFile },
        .{ .id = "sync_out_of_space", .expected = error.NoSpaceLeft, .run = syncAFile },
    });
}

test "file state rows: locks that are not supported or out of resources" {
    try expectEveryCase(.file_state, &.{
        .{ .id = "locks_not_supported", .expected = error.FileLocksUnsupported, .run = lockAFile },
        .{ .id = "lock_out_of_resources", .expected = error.SystemResources, .run = lockAFile },
        .{ .id = "locks_not_supported", .expected = error.FileLocksUnsupported, .run = tryLockAFile },
        .{ .id = "lock_out_of_resources", .expected = error.SystemResources, .run = tryLockAFile },
    });
}

test "file state rows: a lock already held makes the try-lock return false" {
    try expectEveryCase(.file_state, &.{
        .{ .id = "lock_already_held", .expected = error.LockWasHeld, .run = tryLockAFile },
    });
}

test "file state rows: a position on a stream that cannot seek" {
    try expectEveryCase(.file_state, &.{
        .{ .id = "read_or_write_at_a_position_on_a_stream_that_cannot_seek", .expected = error.Unseekable, .run = seekAFile },
        .{ .id = "read_or_write_at_a_position_on_a_stream_that_cannot_seek", .expected = error.Unseekable, .run = seekAFileBy },
        .{ .id = "read_or_write_at_a_position_on_a_stream_that_cannot_seek", .expected = error.Unseekable, .run = positionalRead },
        .{ .id = "read_or_write_at_a_position_on_a_stream_that_cannot_seek", .expected = error.Unseekable, .run = positionalWrite },
    });
}

test "file state rows: a file that is not open for reading and a range another process holds" {
    try expectEveryCase(.file_state, &.{
        .{ .id = "file_not_open_for_reading", .expected = error.NotOpenForReading, .run = positionalRead },
        .{ .id = "file_not_open_for_reading", .expected = error.NotOpenForReading, .run = streamingRead },
        .{ .id = "another_process_holds_a_lock_on_the_range", .expected = error.LockViolation, .run = positionalRead },
        .{ .id = "another_process_holds_a_lock_on_the_range", .expected = error.LockViolation, .run = streamingRead },
        .{ .id = "another_process_holds_a_lock_on_the_range", .expected = error.LockViolation, .run = positionalWrite },
        .{ .id = "another_process_holds_a_lock_on_the_range", .expected = error.LockViolation, .run = streamingWrite },
    });
}

test "file state rows: a position that cannot seek makes a stream reader fall back to streaming" {
    // The reader tries positional reads first and, when told the stream cannot seek, reads by
    // streaming from then on. The whole file still arrives.
    const plan = [_]injector_mod.Injection{at(.file_state, 0, "read_or_write_at_a_position_on_a_stream_that_cannot_seek")};
    var world: World = undefined;
    world.create(&plan);
    defer world.destroy();
    try seed();

    var file = try Dir.cwd().openFile(world.io, "f.txt", .{});
    defer file.close(world.io);
    var buffer: [4]u8 = undefined;
    var reader = file.reader(world.io, &buffer);
    var out: [10]u8 = undefined;
    try reader.interface.readSliceAll(&out);
    try testing.expectEqualStrings("0123456789", &out);
}

// Current directory.

fn readTheCurrentDirectory(world: *World) anyerror!void {
    var buffer: [Dir.max_path_bytes]u8 = undefined;
    _ = try std.process.currentPath(world.io, &buffer);
}

fn changeTheCurrentDirectory(world: *World) anyerror!void {
    try std.process.setCurrentPath(world.io, "dir");
}

test "current directory rows: it was deleted or the path is too long" {
    try expectEveryCase(.current_directory, &.{
        .{ .id = "current_directory_was_deleted", .expected = error.CurrentDirUnlinked, .run = readTheCurrentDirectory },
        .{ .id = "path_too_long", .expected = error.NameTooLong, .run = readTheCurrentDirectory },
        .{ .id = "path_too_long", .expected = error.NameTooLong, .run = changeTheCurrentDirectory },
    });
}

test "current directory rows: changing directory cannot find the current one deleted" {
    var world: World = undefined;
    world.create(&.{});
    defer world.destroy();
    try seed();

    try changeTheCurrentDirectory(&world);
    try testing.expectEqual(@as(usize, 1), world.injector.recorded.items.len);
    const place = world.injector.recorded.items[0];
    for (place.kinds) |index| {
        try testing.expect(!std.mem.eql(u8, failures.kindsOf(.current_directory)[index].id, "current_directory_was_deleted"));
    }
}

// Every row of every group this filesystem answers has a test above and this one checks none was
// left out when a row is added to the table.

// The rows of a group that a test above injects, by effect and id.
const injected_rows = [_]struct { effect: point.Effect, id: []const u8 }{
    .{ .effect = .file_open, .id = "file_not_found" },
    .{ .effect = .file_open, .id = "access_denied" },
    .{ .effect = .file_open, .id = "is_a_directory" },
    .{ .effect = .file_open, .id = "not_a_directory" },
    .{ .effect = .file_open, .id = "already_exists" },
    .{ .effect = .file_open, .id = "name_too_long" },
    .{ .effect = .file_open, .id = "symlink_loop" },
    .{ .effect = .file_open, .id = "out_of_space" },
    .{ .effect = .file_open, .id = "read_only_filesystem" },
    .{ .effect = .file_open, .id = "too_many_open_files" },
    .{ .effect = .read, .id = "input_or_output_error" },
    .{ .effect = .read, .id = "short_read" },
    .{ .effect = .read, .id = "early_end_of_stream" },
    .{ .effect = .read, .id = "read_of_a_directory" },
    .{ .effect = .write, .id = "out_of_space" },
    .{ .effect = .write, .id = "input_or_output_error" },
    .{ .effect = .write, .id = "short_write" },
    .{ .effect = .write, .id = "quota_exceeded" },
    .{ .effect = .write, .id = "read_only_filesystem" },
    .{ .effect = .link, .id = "create_over_an_existing_path" },
    .{ .effect = .link, .id = "create_without_permission" },
    .{ .effect = .link, .id = "create_in_a_missing_directory" },
    .{ .effect = .link, .id = "out_of_space" },
    .{ .effect = .link, .id = "read_a_link_that_is_not_a_link" },
    .{ .effect = .link, .id = "read_a_link_that_is_missing" },
    .{ .effect = .link, .id = "dangling_link" },
    .{ .effect = .link, .id = "link_loop" },
    .{ .effect = .link, .id = "remove_a_link_that_is_missing" },
    .{ .effect = .link, .id = "hard_link_across_filesystems" },
    .{ .effect = .directory_listing, .id = "open_a_missing_directory" },
    .{ .effect = .directory_listing, .id = "open_a_file_as_a_directory" },
    .{ .effect = .directory_listing, .id = "access_denied" },
    .{ .effect = .directory_listing, .id = "error_part_way_through_the_listing" },
    .{ .effect = .directory_listing, .id = "empty_directory" },
    .{ .effect = .directory_listing, .id = "too_many_open_files" },
    .{ .effect = .delete, .id = "file_not_found" },
    .{ .effect = .delete, .id = "access_denied" },
    .{ .effect = .delete, .id = "file_in_use" },
    .{ .effect = .delete, .id = "is_a_directory" },
    .{ .effect = .delete, .id = "not_a_directory" },
    .{ .effect = .delete, .id = "directory_not_empty" },
    .{ .effect = .delete, .id = "symlink_loop" },
    .{ .effect = .delete, .id = "read_only_filesystem" },
    .{ .effect = .delete, .id = "error_part_way_through_deleting_a_tree" },
    .{ .effect = .make_directory, .id = "already_exists" },
    .{ .effect = .make_directory, .id = "access_denied" },
    .{ .effect = .make_directory, .id = "parent_directory_missing" },
    .{ .effect = .make_directory, .id = "parent_is_not_a_directory" },
    .{ .effect = .make_directory, .id = "out_of_space" },
    .{ .effect = .make_directory, .id = "quota_exceeded" },
    .{ .effect = .make_directory, .id = "read_only_filesystem" },
    .{ .effect = .resolve_path, .id = "path_not_found" },
    .{ .effect = .resolve_path, .id = "not_a_directory" },
    .{ .effect = .resolve_path, .id = "access_denied" },
    .{ .effect = .resolve_path, .id = "symlink_loop" },
    .{ .effect = .resolve_path, .id = "name_too_long" },
    .{ .effect = .standard_stream, .id = "input_closed" },
    .{ .effect = .standard_stream, .id = "input_or_output_error" },
    .{ .effect = .standard_stream, .id = "output_closed" },
    .{ .effect = .standard_stream, .id = "short_write" },
    .{ .effect = .rename_copy, .id = "source_not_found" },
    .{ .effect = .rename_copy, .id = "access_denied" },
    .{ .effect = .rename_copy, .id = "destination_is_a_non_empty_directory" },
    .{ .effect = .rename_copy, .id = "destination_is_a_directory" },
    .{ .effect = .rename_copy, .id = "file_in_use" },
    .{ .effect = .rename_copy, .id = "across_filesystems" },
    .{ .effect = .rename_copy, .id = "out_of_space" },
    .{ .effect = .rename_copy, .id = "quota_exceeded" },
    .{ .effect = .rename_copy, .id = "read_only_filesystem" },
    .{ .effect = .rename_copy, .id = "copy_fails_part_way_through" },
    .{ .effect = .attributes, .id = "access_denied" },
    .{ .effect = .attributes, .id = "not_permitted" },
    .{ .effect = .attributes, .id = "file_not_found" },
    .{ .effect = .attributes, .id = "input_or_output_error" },
    .{ .effect = .attributes, .id = "read_only_filesystem" },
    .{ .effect = .attributes, .id = "symlink_loop" },
    .{ .effect = .file_state, .id = "length_cannot_be_read" },
    .{ .effect = .file_state, .id = "resize_past_the_size_limit" },
    .{ .effect = .file_state, .id = "file_cannot_be_resized" },
    .{ .effect = .file_state, .id = "sync_fails" },
    .{ .effect = .file_state, .id = "sync_out_of_space" },
    .{ .effect = .file_state, .id = "locks_not_supported" },
    .{ .effect = .file_state, .id = "lock_out_of_resources" },
    .{ .effect = .file_state, .id = "lock_already_held" },
    .{ .effect = .file_state, .id = "read_or_write_at_a_position_on_a_stream_that_cannot_seek" },
    .{ .effect = .file_state, .id = "file_not_open_for_reading" },
    .{ .effect = .file_state, .id = "another_process_holds_a_lock_on_the_range" },
    .{ .effect = .current_directory, .id = "current_directory_was_deleted" },
    .{ .effect = .current_directory, .id = "path_too_long" },
};

test "every row of every group of files and directories is among the rows the tests above inject" {
    const groups = [_]point.Effect{
        .file_open,
        .read,
        .write,
        .link,
        .directory_listing,
        .delete,
        .make_directory,
        .resolve_path,
        .standard_stream,
        .rename_copy,
        .attributes,
        .file_state,
        .current_directory,
    };
    for (groups) |effect| {
        for (failures.kindsOf(effect)) |kind| {
            var found = false;
            for (injected_rows) |row| {
                if (row.effect == effect and std.mem.eql(u8, row.id, kind.id)) {
                    found = true;
                }
            }
            if (!found) {
                std.debug.print("no test injects {s} in {s}\n", .{ kind.id, @tagName(effect) });
            }
            try testing.expect(found);
        }
    }
}
