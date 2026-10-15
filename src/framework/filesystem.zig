// The filesystem a function under test runs against: a tree held in memory, with no real disk behind
// any call. A call that reached the real disk would be a defect.
//
// It is layered over an `Io` the way the other simulated effects are: `install` copies the `Io`
// underneath into room the caller owns and replaces the entries for files and directories, so the
// two installs of the simulated world can be applied one after the other in either order. Handles
// that are not the simulated ones and every call that is not about files, go to the `Io` underneath.
//
// Every call that can fail asks the injector once per effect it can fail in and returns the error
// the row of `docs/FAILURES.md` says. With no failure injected a call behaves as the real
// filesystem does: symbolic links are followed, directory listings come back sorted, permissions
// are honoured and a file's modified time is the moment it was written.
//
// The state is module-level, so the `Io` can reach it without a pointer and `reset` gives a fresh
// tree. The helpers at the end build and inspect the tree for a scenario or an expectation function
// without asking the injector.

const std = @import("std");
const injector_mod = @import("injector.zig");
const faults = @import("filesystem_faults.zig");
const tree = @import("filesystem_tree.zig");

const Dir = std.Io.Dir;
const File = std.Io.File;
const Node = tree.Node;
const Handle = std.posix.fd_t;

// Where this filesystem's handles start. Far above any descriptor a process is given, so a handle
// from here is never mistaken for a real one and a real one is never mistaken for one from here. A
// process is held to its limit on open files, and that limit is a small fraction of this value.
pub const first_handle: Handle = 1 << 29;

// What `Dir.cwd()` holds. The directory a relative path starts from.
const cwd_handle: Handle = std.posix.AT.FDCWD;

// The most bytes one call that copies from a reader moves. It is a page, as the real copy loops
// move, so a file larger than one page takes more than one call and a copy has a middle.
const copy_chunk_bytes: usize = 4096;

// One open handle. Kept by position, so a handle is `first_handle` plus where it is in the list and
// nothing has to be searched for.
const Open = struct {
    // What the handle refers to. Still valid after the last name of a file is removed.
    node: *Node,

    // Whether the handle was opened to read.
    readable: bool,

    // Whether the handle was opened to write.
    writable: bool,

    // Where the next streaming read or write lands. A positional one carries its own offset.
    position: u64 = 0,

    // Closed handles stay in the list, because removing one would move every handle after it.
    is_open: bool = true,

    // The advisory lock this handle holds.
    lock: File.Lock = .none,

    // How many bytes have been copied into this handle by a call that reads from another file.
    copied: u64 = 0,
};

// The `Io` underneath, set by `install`.
var underneath: std.Io = undefined;

// Whether the tree has been made. A tree is made on first use, so helpers work before `install`.
var prepared: bool = false;

// Every handle given out, in the order given out.
var opens: std.ArrayList(Open) = .empty;

// Standard input, output and error. They are the handles 0, 1 and 2 as a process has them, but
// they are held in memory: input is what a scenario set and output is what was written.
var standard_opens: [3]Open = undefined;

// How many files and directories have been removed since the last reset. A failure part way
// through removing a tree is offered only once an earlier entry has gone.
var removed_count: u32 = 0;

// The number the next temporary file made for an atomic write is named after. A counter and not a
// random number so two runs name them alike.
var atomic_counter: u64 = 0;

// Makes the tree and the standard streams if that has not been done.
fn prepare() void {
    if (!prepared) {
        reset();
    }
}

// Throws everything away and starts with an empty tree, no open handles and empty standard
// streams. The injector is not touched: it belongs to the world.
pub fn reset() void {
    tree.reset();
    opens = .empty;
    removed_count = 0;
    atomic_counter = 0;
    for (&standard_opens, 0..) |*slot, number| {
        const node = tree.newNode(.character_device, 0o620) catch {
            @panic("faultline: out of memory making the standard streams");
        };
        node.link_count = 1;
        slot.* = .{ .node = node, .readable = number == 0, .writable = number != 0 };
    }
    prepared = true;
}

// Layers the in-memory filesystem over `io`. The vtable is written into `room` and not returned by
// value, because an `Io` holds a pointer to its vtable and one on this function's stack would be
// gone by the time it is read. Everything this does not replace is `io`'s own, so a later install
// of another part of the simulated world copies this one's entries and keeps them.
pub fn install(io: std.Io, room: *std.Io.VTable, injector: *injector_mod.Injector) std.Io {
    underneath = io;
    faults.injector = injector;
    prepare();

    room.* = io.vtable.*;

    room.dirCreateDir = createDir;
    room.dirCreateDirPath = createDirPath;
    room.dirCreateDirPathOpen = createDirPathOpen;
    room.dirOpenDir = openDir;
    room.dirStat = statDir;
    room.dirStatFile = statFile;
    room.dirAccess = access;
    room.dirCreateFile = createFile;
    room.dirCreateFileAtomic = createFileAtomic;
    room.dirOpenFile = openFile;
    room.dirClose = closeDirs;
    room.dirRead = readDirectory;
    room.dirRealPath = realPathOfDir;
    room.dirRealPathFile = realPathOfFileIn;
    room.dirDeleteFile = deleteFile;
    room.dirDeleteDir = deleteDir;
    room.dirRename = rename;
    room.dirRenamePreserve = renamePreserve;
    room.dirSymLink = symLink;
    room.dirReadLink = readLink;
    room.dirSetOwner = setDirOwner;
    room.dirSetFileOwner = setOwnerByPath;
    room.dirSetPermissions = setDirPermissions;
    room.dirSetFilePermissions = setPermissionsByPath;
    room.dirSetTimestamps = setTimestampsByPath;
    room.dirHardLink = hardLinkByPath;

    room.fileStat = statOpenFile;
    room.fileLength = lengthOf;
    room.fileClose = closeFiles;
    room.fileWritePositional = writePositional;
    room.fileWriteFileStreaming = writeFileStreaming;
    room.fileWriteFilePositional = writeFilePositional;
    room.fileReadPositional = readPositional;
    room.fileSeekBy = seekBy;
    room.fileSeekTo = seekTo;
    room.fileSync = sync;
    room.fileIsTty = isTty;
    room.fileEnableAnsiEscapeCodes = enableAnsiEscapeCodes;
    room.fileSupportsAnsiEscapeCodes = supportsAnsiEscapeCodes;
    room.fileSetLength = setLength;
    room.fileSetOwner = setFileOwner;
    room.fileSetPermissions = setFilePermissions;
    room.fileSetTimestamps = setTimestamps;
    room.fileLock = lock;
    room.fileTryLock = tryLock;
    room.fileUnlock = unlock;
    room.fileDowngradeLock = downgradeLock;
    room.fileRealPath = realPathOfOpenFile;
    room.fileHardLink = hardLinkOpenFile;
    room.fileMemoryMapCreate = createMemoryMap;

    room.processExecutableOpen = openExecutable;
    room.processCurrentPath = currentPath;
    room.processSetCurrentDir = setCurrentDir;
    room.processSetCurrentPath = setCurrentPath;

    // Reading and writing a stream arrive as an `Operation`, which is also how a socket is reached.
    // Only the two file operations are answered here and the rest go underneath.
    room.operate = operate;

    // A batch of operations, which is how `std.process.run` reads a child's two pipes at once. The
    // operations are made one after another through `operate`, because a simulated file never has
    // to wait for anything and a batch made underneath would read the simulated handles as real
    // ones.
    room.batchAwaitAsync = awaitBatchAsync;
    room.batchAwaitConcurrent = awaitBatchConcurrent;

    return .{ .userdata = io.userdata, .vtable = room };
}

// Whether `handle` is one this filesystem gave out, or the current directory.
pub fn isSimulatedDirHandle(handle: Handle) bool {
    return handle == cwd_handle or handle >= first_handle;
}

// Whether `handle` is one this filesystem gave out, or a standard stream.
pub fn isSimulatedFileHandle(handle: Handle) bool {
    return (handle >= 0 and handle <= 2) or handle >= first_handle;
}

// The open handle for `handle`, or null when it was never given out or has been closed.
fn openOf(handle: Handle) ?*Open {
    if (handle >= 0 and handle <= 2) {
        return &standard_opens[@intCast(handle)];
    }
    if (handle < first_handle) {
        return null;
    }
    const index: usize = @intCast(handle - first_handle);
    if (index >= opens.items.len) {
        return null;
    }
    const found = &opens.items[index];
    if (!found.is_open) {
        return null;
    }
    return found;
}

// The directory node a `Dir` stands for, or null when it is not an open directory.
fn startOf(dir: Dir) ?*Node {
    prepare();
    if (dir.handle == cwd_handle) {
        return tree.currentDirectory();
    }
    const found = openOf(dir.handle) orelse {
        return null;
    };
    if (found.node.kind != .directory) {
        return null;
    }
    return found.node;
}

// Gives out a handle for `node`.
fn newHandle(node: *Node, readable: bool, writable: bool) std.mem.Allocator.Error!Handle {
    try opens.append(tree.allocator(), .{ .node = node, .readable = readable, .writable = writable });
    return first_handle + @as(Handle, @intCast(opens.items.len - 1));
}

// The error a failed lookup is reported as in a call whose error set is `Set`. A set without
// `NotDir`, `SymLinkLoop` or `NameTooLong` gets `FileNotFound`, the way a real call reports a path
// below a file as missing when its set has no better word.
fn narrow(comptime Set: type, err: tree.ResolveError) Set {
    return switch (err) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.SymLinkLoop => if (comptime faults.hasError(Set, "SymLinkLoop")) error.SymLinkLoop else error.FileNotFound,
        error.NameTooLong => if (comptime faults.hasError(Set, "NameTooLong")) error.NameTooLong else error.FileNotFound,
        error.NotDir => if (comptime faults.hasError(Set, "NotDir")) error.NotDir else error.FileNotFound,
    };
}

// The ids of the rows that can happen to any call that takes a path.
const path_ids = [_][]const u8{ "file_not_found", "access_denied", "not_a_directory", "name_too_long", "symlink_loop" };

// The ids of the rows that can happen to a call that opens a file.
const open_ids = path_ids ++ [_][]const u8{ "is_a_directory", "too_many_open_files" };

// The ids of the rows that can happen to a call that opens a file to write it.
const open_write_ids = open_ids ++ [_][]const u8{"read_only_filesystem"};

// The ids of the rows that can happen to a call that creates a file.
const create_ids = open_write_ids ++ [_][]const u8{"out_of_space"};

// The ids of the rows that can happen to a call that creates a file and must not find it there.
const create_exclusive_ids = create_ids ++ [_][]const u8{"already_exists"};

// The ids of the rows for a failed attribute change.
const attribute_ids = [_][]const u8{ "access_denied", "not_permitted", "file_not_found", "input_or_output_error", "read_only_filesystem", "symlink_loop" };

// The ids of the rows for a failed read that could end early or short.
const read_ids = [_][]const u8{ "input_or_output_error", "read_of_a_directory" };

// The ids of the rows for a read that has at least one byte to give.
const read_early_ids = read_ids ++ [_][]const u8{"early_end_of_stream"};

// The ids of the rows for a read that has at least two bytes to give.
const read_short_ids = read_early_ids ++ [_][]const u8{"short_read"};

// The ids of the rows for a failed write.
const write_ids = [_][]const u8{ "out_of_space", "input_or_output_error", "quota_exceeded", "read_only_filesystem" };

// The ids of the rows for a write of at least two bytes.
const write_short_ids = write_ids ++ [_][]const u8{"short_write"};

// The ids of the rows that can happen to a read or write at a position, which is a question about
// the state of the stream.
const stream_state_ids = [_][]const u8{ "read_or_write_at_a_position_on_a_stream_that_cannot_seek", "file_not_open_for_reading", "another_process_holds_a_lock_on_the_range" };

// The ids of the rows for a call that removes a name, before an earlier removal has happened.
const delete_ids = [_][]const u8{ "file_not_found", "access_denied", "file_in_use", "is_a_directory", "not_a_directory", "symlink_loop", "read_only_filesystem" };

// The ids of the rows for a call that removes a file named with no `/` in it: an entry of the open
// directory itself. No part of such a path can be something other than a directory, so the call
// cannot fail with `NotDir` on a real system, and the standard library's `deleteTree` treats that
// error as one that cannot happen.
const delete_bare_name_ids = [_][]const u8{ "file_not_found", "access_denied", "file_in_use", "is_a_directory", "symlink_loop", "read_only_filesystem" };

// The ids of the rows for a call that removes a directory.
const delete_directory_ids = [_][]const u8{ "file_not_found", "access_denied", "file_in_use", "not_a_directory", "directory_not_empty", "symlink_loop", "read_only_filesystem" };

// The ids of the rows for a call that makes a directory.
const make_directory_ids = [_][]const u8{ "already_exists", "access_denied", "parent_directory_missing", "parent_is_not_a_directory", "out_of_space", "quota_exceeded", "read_only_filesystem" };

// The ids of the rows for a call that makes a link.
const make_link_ids = [_][]const u8{ "create_over_an_existing_path", "create_without_permission", "create_in_a_missing_directory", "out_of_space" };

// The ids of the rows for a call that moves a name.
const rename_ids = [_][]const u8{ "source_not_found", "access_denied", "destination_is_a_non_empty_directory", "destination_is_a_directory", "file_in_use", "across_filesystems", "out_of_space", "quota_exceeded", "read_only_filesystem" };

// The ids of the rows for a call that finds the absolute path of something.
const resolve_ids = [_][]const u8{ "path_not_found", "not_a_directory", "access_denied", "symlink_loop", "name_too_long" };

// The ids of the rows for a call that opens a directory to list it.
const open_directory_ids = [_][]const u8{ "open_a_missing_directory", "open_a_file_as_a_directory", "access_denied", "too_many_open_files" };

// What a file looks like to `stat`.
fn statOf(node: *const Node) File.Stat {
    return .{
        .inode = node.inode,
        .nlink = @intCast(node.link_count),
        .size = switch (node.kind) {
            .directory => 4096,
            .character_device => 0,
            else => node.data.items.len,
        },
        .permissions = File.Permissions.fromMode(node.mode & 0o7777),
        .kind = node.kind,
        .atime = node.accessed,
        .mtime = node.modified,
        .ctime = node.changed,
        .block_size = 4096,
    };
}

// Whether a lookup ended at a name that is "." or "..", which cannot be removed, renamed or created.
fn isDotName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

// Gives the file or link at `resolved` a new owner of the lock, or checks that it may be taken.
fn takeLock(open: *Open, wanted: File.Lock, nonblocking: bool) error{WouldBlock}!void {
    if (wanted == .none) {
        return;
    }
    if (isLockedByAnother(open, wanted) and nonblocking) {
        return error.WouldBlock;
    }

    // A blocking lock that another handle holds would wait for ever, because the one process this
    // simulates is the only one that could release it. It is granted instead so the call returns.
    open.lock = wanted;
}

// Whether another open handle on the same node holds a lock that does not allow `wanted`.
fn isLockedByAnother(open: *const Open, wanted: File.Lock) bool {
    for (opens.items) |*other| {
        if (other == open or !other.is_open or other.node != open.node) {
            continue;
        }
        switch (other.lock) {
            .none => {},
            .shared => {
                if (wanted == .exclusive) {
                    return true;
                }
            },
            .exclusive => {
                return true;
            },
        }
    }
    return false;
}

// Opens a file or directory that exists, checking the permissions the options ask for.
fn openFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenFileOptions) File.OpenError!File {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirOpenFile(userdata, dir, sub_path, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const failure = if (options.isWrite())
        faults.failWith(.file_open, File.OpenError, &open_write_ids)
    else
        faults.failWith(.file_open, File.OpenError, &open_ids);
    if (failure) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(File.OpenError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    switch (node.kind) {
        .sym_link => {
            return error.SymLinkLoop;
        },
        .directory => {
            if (options.isWrite() or !options.allow_directory) {
                return error.IsDir;
            }
        },
        else => {},
    }
    if ((options.isRead() and !node.mayRead()) or (options.isWrite() and !node.mayWrite())) {
        return error.AccessDenied;
    }
    const handle = newHandle(node, options.isRead() and !options.path_only, options.isWrite() and !options.path_only) catch {
        return error.SystemResources;
    };
    try takeLock(openOf(handle).?, options.lock, options.lock_nonblocking);
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

// Opens a file for writing, making it when it is not there and emptying it when it is.
fn createFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileOptions) File.OpenError!File {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirCreateFile(userdata, dir, sub_path, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const failure = if (options.exclusive)
        faults.failWith(.file_open, File.OpenError, &create_exclusive_ids)
    else
        faults.failWith(.file_open, File.OpenError, &create_ids);
    if (failure) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = !options.exclusive, .inject = true }) catch |err| {
        return narrow(File.OpenError, err);
    };
    var node: *Node = undefined;
    if (found.node) |existing| {
        if (options.exclusive) {
            return error.PathAlreadyExists;
        }
        if (existing.kind == .directory) {
            return error.IsDir;
        }
        if (!existing.mayWrite() or (options.read and !existing.mayRead())) {
            return error.AccessDenied;
        }
        node = existing;
    } else {
        if (isDotName(found.name) or found.name.len == 0) {
            return error.FileNotFound;
        }
        if (!found.dir.mayWrite() or !found.dir.maySearch()) {
            return error.AccessDenied;
        }
        node = tree.create(found.dir, found.name, .file, options.permissions.toMode() & 0o7777) catch {
            return error.NoSpaceLeft;
        };
    }
    const handle = newHandle(node, options.read, true) catch {
        return error.SystemResources;
    };
    try takeLock(openOf(handle).?, options.lock, options.lock_nonblocking);
    if (options.truncate and found.node != null) {
        tree.resizeData(node, 0) catch {
            return error.NoSpaceLeft;
        };
    }
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

// Makes a file with no name yet that a later call gives its name, as an atomic write does.
fn createFileAtomic(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.CreateFileAtomicOptions) Dir.CreateFileAtomicError!File.Atomic {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirCreateFileAtomic(userdata, dir, sub_path, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.file_open, Dir.CreateFileAtomicError, &create_ids)) |err| {
        return err;
    }
    const slash = std.mem.lastIndexOfScalar(u8, sub_path, '/');
    const parent_path = if (slash) |at| (if (at == 0) "/" else sub_path[0..at]) else ".";
    const base_name = if (slash) |at| sub_path[at + 1 ..] else sub_path;
    if (base_name.len == 0 or isDotName(base_name)) {
        return error.FileNotFound;
    }
    if (options.make_path) {
        _ = makePathChecked(start, parent_path, .default_dir) catch |err| {
            return narrowMake(Dir.CreateFileAtomicError, err);
        };
    }
    const found = tree.resolve(start, parent_path, .{ .inject = true }) catch |err| {
        return narrow(Dir.CreateFileAtomicError, err);
    };
    const parent = found.node orelse {
        return error.FileNotFound;
    };
    if (parent.kind != .directory) {
        return error.NotDir;
    }
    if (!parent.mayWrite() or !parent.maySearch()) {
        return error.AccessDenied;
    }
    var name_buffer: [16]u8 = undefined;
    while (true) {
        name_buffer = std.fmt.hex(atomic_counter);
        if (tree.lookup(parent, &name_buffer) == null) {
            break;
        }
        atomic_counter += 1;
    }
    const used = atomic_counter;
    atomic_counter += 1;
    const node = tree.create(parent, &name_buffer, .file, options.permissions.toMode() & 0o7777) catch {
        return error.NoSpaceLeft;
    };
    const file_handle = newHandle(node, true, true) catch {
        return error.SystemResources;
    };
    const dir_handle = newHandle(parent, true, false) catch {
        return error.SystemResources;
    };
    const kept_name = tree.allocator().dupe(u8, base_name) catch {
        return error.SystemResources;
    };
    return .{
        .file = .{ .handle = file_handle, .flags = .{ .nonblocking = false } },
        .file_basename_hex = used,
        .file_open = true,
        .file_exists = true,
        .dir = .{ .handle = dir_handle },
        .close_dir_on_deinit = true,
        .dest_sub_path = kept_name,
    };
}

// Whether a name is where the code under test says, without opening it.
fn access(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.AccessOptions) Dir.AccessError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirAccess(userdata, dir, sub_path, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const failure = if (options.write)
        faults.failWith(.file_open, Dir.AccessError, &open_write_ids)
    else
        faults.failWith(.file_open, Dir.AccessError, &open_ids);
    if (failure) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(Dir.AccessError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if ((options.read and !node.mayRead()) or (options.write and !node.mayWrite()) or (options.execute and !node.maySearch())) {
        return error.AccessDenied;
    }
}

// What a name inside a directory is, following a link at the last name when asked.
fn statFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.StatFileOptions) Dir.StatFileError!File.Stat {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirStatFile(userdata, dir, sub_path, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.file_open, Dir.StatFileError, &open_ids)) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(Dir.StatFileError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    return statOf(node);
}

// What an open directory is.
fn statDir(userdata: ?*anyopaque, dir: Dir) Dir.StatError!Dir.Stat {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirStat(userdata, dir);
    }
    if (faults.failWith(.file_state, Dir.StatError, &.{"length_cannot_be_read"})) |err| {
        return err;
    }
    const node = startOf(dir) orelse {
        return error.Unexpected;
    };
    return statOf(node);
}

// Opens a directory so it can be searched and listed.
fn openDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.OpenOptions) Dir.OpenError!Dir {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirOpenDir(userdata, dir, sub_path, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.directory_listing, Dir.OpenError, &open_directory_ids)) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(Dir.OpenError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind != .directory) {
        return error.NotDir;
    }
    if (!node.mayRead()) {
        return error.AccessDenied;
    }
    const handle = newHandle(node, true, false) catch {
        return error.SystemResources;
    };
    return .{ .handle = handle };
}

// Lets go of directories.
fn closeDirs(userdata: ?*anyopaque, closing: []const Dir) void {
    for (closing) |dir| {
        if (!isSimulatedDirHandle(dir.handle)) {
            underneath.vtable.dirClose(userdata, &.{dir});
            continue;
        }
        if (dir.handle >= first_handle) {
            if (openOf(dir.handle)) |found| {
                found.is_open = false;
            }
        }
    }
}

// Hands over the next entries of a directory, in name order.
fn readDirectory(userdata: ?*anyopaque, reader: *Dir.Reader, into: []Dir.Entry) Dir.Reader.Error!usize {
    if (!isSimulatedDirHandle(reader.dir.handle)) {
        return underneath.vtable.dirRead(userdata, reader, into);
    }
    if (reader.state == .reset) {
        reader.index = 0;
        reader.state = .reading;
    }
    if (reader.state == .finished) {
        return 0;
    }
    const node = startOf(reader.dir) orelse {
        reader.state = .finished;
        return 0;
    };

    // `index` counts the entries already handed over. The names point into the tree, which owns
    // them, so nothing is kept in `buffer`.
    const names = node.children.items;
    if (reader.index == 0) {
        if (faults.ask(.directory_listing, Dir.Reader.Error, &.{ "empty_directory", "access_denied" })) |picked| {
            if (faults.isKind(.directory_listing, "empty_directory", picked)) {
                reader.state = .finished;
                return 0;
            }
            return faults.errorOf(.directory_listing, Dir.Reader.Error, picked);
        }
    } else if (reader.index < names.len) {
        if (faults.failWith(.directory_listing, Dir.Reader.Error, &.{"error_part_way_through_the_listing"})) |err| {
            return err;
        }
    }
    var written: usize = 0;
    while (written < into.len and reader.index < names.len) {
        const child = names[reader.index];
        into[written] = .{ .name = child.name, .kind = child.node.kind, .inode = child.node.inode };
        written += 1;
        reader.index += 1;
    }

    // `Reader.next` loops until the state says finished and does not stop on an empty read, so a
    // listing that has run out has to say so.
    if (written < into.len) {
        reader.state = .finished;
    }
    return written;
}

// Writes the absolute path of an open directory into `out`.
fn realPathOfDir(userdata: ?*anyopaque, dir: Dir, out: []u8) Dir.RealPathError!usize {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirRealPath(userdata, dir, out);
    }
    if (faults.failWith(.resolve_path, Dir.RealPathError, &resolve_ids)) |err| {
        return err;
    }
    const node = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const path = try tree.pathOf(node, out) orelse {
        return error.FileNotFound;
    };
    return path.len;
}

// Writes the absolute path of a name inside a directory into `out`, with every link followed.
fn realPathOfFileIn(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, out: []u8) Dir.RealPathFileError!usize {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirRealPathFile(userdata, dir, sub_path, out);
    }
    if (faults.failWith(.resolve_path, Dir.RealPathFileError, &resolve_ids)) |err| {
        return err;
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const found = tree.resolve(start, sub_path, .{ .inject = true }) catch |err| {
        return narrow(Dir.RealPathFileError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    const path = try tree.pathOf(node, out) orelse {
        return error.FileNotFound;
    };
    return path.len;
}

// Writes the absolute path of an open file into `out`.
fn realPathOfOpenFile(userdata: ?*anyopaque, file: File, out: []u8) File.RealPathError!usize {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileRealPath(userdata, file, out);
    }
    if (faults.failWith(.resolve_path, File.RealPathError, &resolve_ids)) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.FileNotFound;
    };
    if (open.node.kind == .character_device) {
        return error.FileNotFound;
    }
    const path = try tree.pathOf(open.node, out) orelse {
        return error.FileNotFound;
    };
    return path.len;
}

// Removes a name that is not a directory. A link is removed and not followed.
fn deleteFile(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirDeleteFile(userdata, dir, sub_path);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const picked = if (std.mem.indexOfScalar(u8, sub_path, '/') == null)
        askDeleteFile(&delete_bare_name_ids)
    else
        askDeleteFile(&delete_ids);
    if (picked) |kind| {
        if (faults.isKind(.delete, "error_part_way_through_deleting_a_tree", kind)) {
            return error.FileSystem;
        }
        return faults.errorOf(.delete, Dir.DeleteFileError, kind);
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Dir.DeleteFileError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind == .directory) {
        return error.IsDir;
    }
    if (!found.dir.mayWrite() or !found.dir.maySearch()) {
        return error.AccessDenied;
    }
    if (node.kind == .sym_link) {
        if (faults.failWith(.link, Dir.DeleteFileError, &.{"remove_a_link_that_is_missing"})) |err| {
            return err;
        }
    }
    _ = tree.detach(found.dir, found.name);
    tree.release(node);
    removed_count += 1;
}

// Which failure, if any, a call that removes a file has, from the rows `ids` and, once something
// has been removed, an error part way through deleting a tree.
fn askDeleteFile(comptime ids: []const []const u8) ?u8 {
    if (removed_count > 0) {
        return faults.ask(.delete, Dir.DeleteFileError, ids ++ &[_][]const u8{"error_part_way_through_deleting_a_tree"});
    }
    return faults.ask(.delete, Dir.DeleteFileError, ids);
}

// Removes an empty directory.
fn deleteDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirDeleteDir(userdata, dir, sub_path);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const picked = if (removed_count > 0)
        faults.ask(.delete, Dir.DeleteDirError, &(delete_directory_ids ++ [_][]const u8{"error_part_way_through_deleting_a_tree"}))
    else
        faults.ask(.delete, Dir.DeleteDirError, &delete_directory_ids);
    if (picked) |kind| {
        if (faults.isKind(.delete, "error_part_way_through_deleting_a_tree", kind)) {
            return error.FileSystem;
        }
        return faults.errorOf(.delete, Dir.DeleteDirError, kind);
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Dir.DeleteDirError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind != .directory) {
        return error.NotDir;
    }
    if (isDotName(found.name) or node == tree.root()) {
        return error.FileBusy;
    }
    if (node.children.items.len > 0) {
        return error.DirNotEmpty;
    }
    if (!found.dir.mayWrite() or !found.dir.maySearch()) {
        return error.AccessDenied;
    }
    _ = tree.detach(found.dir, found.name);
    removed_count += 1;
}

// Makes the missing directories along `path`, checking that each parent can be written. The
// permissions apply to the directories that are made.
fn makePathChecked(start: *Node, path: []const u8, permissions: File.Permissions) MakeError!struct { node: *Node, created: bool } {
    if (path.len == 0) {
        return error.BadPathName;
    }
    if (path.len >= tree.max_path_bytes) {
        return error.NameTooLong;
    }
    var current = if (path[0] == '/') tree.root() else start;
    var created = false;
    var names = std.mem.tokenizeScalar(u8, path, '/');
    while (names.next()) |name| {
        if (name.len > tree.max_name_bytes) {
            return error.NameTooLong;
        }
        if (std.mem.eql(u8, name, ".")) {
            continue;
        }
        if (std.mem.eql(u8, name, "..")) {
            current = current.parent orelse current;
            continue;
        }
        if (!current.maySearch()) {
            return error.AccessDenied;
        }
        if (tree.lookup(current, name) != null) {
            const found = try tree.resolve(current, name, .{ .inject = true });
            const there = found.node orelse {
                return error.FileNotFound;
            };
            if (there.kind != .directory) {
                return error.NotDir;
            }
            current = there;
            continue;
        }
        if (!current.mayWrite()) {
            return error.AccessDenied;
        }
        current = tree.create(current, name, .directory, permissions.toMode() & 0o7777) catch {
            return error.NoSpaceLeft;
        };
        created = true;
    }
    return .{ .node = current, .created = created };
}

// The errors making directories along a path can end in.
const MakeError = tree.ResolveError || error{ BadPathName, NoSpaceLeft };

// The error a failed `makePathChecked` is reported as in a call whose error set is `Set`.
fn narrowMake(comptime Set: type, err: MakeError) Set {
    return switch (err) {
        error.BadPathName => error.BadPathName,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.SymLinkLoop => error.SymLinkLoop,
        error.NameTooLong => error.NameTooLong,
        error.NotDir => error.NotDir,
    };
}

// Makes one directory. Its parent has to be there.
fn createDir(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirCreateDir(userdata, dir, sub_path, permissions);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.make_directory, Dir.CreateDirError, &make_directory_ids)) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Dir.CreateDirError, err);
    };
    if (found.node != null) {
        return error.PathAlreadyExists;
    }
    if (isDotName(found.name) or found.name.len == 0) {
        return error.PathAlreadyExists;
    }
    if (!found.dir.mayWrite() or !found.dir.maySearch()) {
        return error.AccessDenied;
    }
    _ = tree.create(found.dir, found.name, .directory, permissions.toMode() & 0o7777) catch {
        return error.NoSpaceLeft;
    };
}

// Makes a directory and every missing directory above it.
fn createDirPath(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirCreateDirPath(userdata, dir, sub_path, permissions);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.make_directory, Dir.CreateDirPathError, &make_directory_ids)) |err| {
        return err;
    }
    const made = makePathChecked(start, sub_path, permissions) catch |err| {
        return narrowMake(Dir.CreateDirPathError, err);
    };
    return if (made.created) .created else .existed;
}

// Makes a directory and every missing directory above it, then opens it.
fn createDirPathOpen(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirCreateDirPathOpen(userdata, dir, sub_path, permissions, options);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.make_directory, Dir.CreateDirPathOpenError, &make_directory_ids)) |err| {
        return err;
    }
    const made = makePathChecked(start, sub_path, permissions) catch |err| {
        return narrowMake(Dir.CreateDirPathOpenError, err);
    };
    if (!made.node.mayRead()) {
        return error.AccessDenied;
    }
    const handle = newHandle(made.node, true, false) catch {
        return error.SystemResources;
    };
    return .{ .handle = handle };
}

// Moves a name, replacing what is at the new name when that is allowed. `preserve` makes an
// existing name at the new place an error.
fn moveName(
    comptime Set: type,
    comptime preserve: bool,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Set!void {
    const old_start = startOf(old_dir) orelse {
        return error.FileNotFound;
    };
    const new_start = startOf(new_dir) orelse {
        return error.FileNotFound;
    };
    const source = tree.resolve(old_start, old_sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Set, err);
    };
    const moving = source.node orelse {
        return error.FileNotFound;
    };
    const target = tree.resolve(new_start, new_sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Set, err);
    };
    if (isDotName(source.name) or isDotName(target.name) or target.name.len == 0 or moving == tree.root()) {
        return error.FileBusy;
    }
    if (target.node == moving) {
        return;
    }
    if (!source.dir.mayWrite() or !target.dir.mayWrite() or !source.dir.maySearch() or !target.dir.maySearch()) {
        return error.AccessDenied;
    }
    if (moving.kind == .directory) {
        var above: ?*Node = target.dir;
        while (above) |walking| {
            if (walking == moving) {
                return error.Unexpected;
            }
            above = walking.parent;
        }
        if (target.node) |there| {
            if (there.kind != .directory) {
                return error.NotDir;
            }
            if (there.children.items.len > 0) {
                return error.DirNotEmpty;
            }
        }
    } else if (target.node) |there| {
        if (there.kind == .directory) {
            return error.IsDir;
        }
    }
    if (preserve and target.node != null) {
        return error.PathAlreadyExists;
    }
    if (target.node) |there| {
        _ = tree.detach(target.dir, target.name);
        tree.release(there);
    }
    _ = tree.detach(source.dir, source.name);
    tree.attach(target.dir, target.name, moving) catch {
        return error.NoSpaceLeft;
    };
}

// Moves a name, replacing what is at the new name. This is what makes an atomic write atomic: the
// writer writes a temporary file and renames it onto the real one.
fn rename(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    if (!isSimulatedDirHandle(old_dir.handle) and !isSimulatedDirHandle(new_dir.handle)) {
        return underneath.vtable.dirRename(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
    if (!isSimulatedDirHandle(old_dir.handle) or !isSimulatedDirHandle(new_dir.handle)) {
        return error.CrossDevice;
    }
    if (faults.failWith(.rename_copy, Dir.RenameError, &rename_ids)) |err| {
        return err;
    }
    return moveName(Dir.RenameError, false, old_dir, old_sub_path, new_dir, new_sub_path);
}

// Moves a name and refuses when something is at the new name.
fn renamePreserve(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenamePreserveError!void {
    if (!isSimulatedDirHandle(old_dir.handle) and !isSimulatedDirHandle(new_dir.handle)) {
        return underneath.vtable.dirRenamePreserve(userdata, old_dir, old_sub_path, new_dir, new_sub_path);
    }
    if (!isSimulatedDirHandle(old_dir.handle) or !isSimulatedDirHandle(new_dir.handle)) {
        return error.CrossDevice;
    }
    if (faults.failWith(.rename_copy, Dir.RenamePreserveError, &rename_ids)) |err| {
        return err;
    }
    return moveName(Dir.RenamePreserveError, true, old_dir, old_sub_path, new_dir, new_sub_path);
}

// Makes a symbolic link named `link_path` that holds `target`. The target does not have to exist.
fn symLink(userdata: ?*anyopaque, dir: Dir, target: []const u8, link_path: []const u8, flags: Dir.SymLinkFlags) Dir.SymLinkError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirSymLink(userdata, dir, target, link_path, flags);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.link, Dir.SymLinkError, &make_link_ids)) |err| {
        return err;
    }
    if (target.len == 0) {
        return error.FileNotFound;
    }
    if (target.len >= tree.max_path_bytes) {
        return error.NameTooLong;
    }
    const found = tree.resolve(start, link_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Dir.SymLinkError, err);
    };
    if (found.node != null or isDotName(found.name) or found.name.len == 0) {
        return error.PathAlreadyExists;
    }
    if (!found.dir.mayWrite() or !found.dir.maySearch()) {
        return error.AccessDenied;
    }
    const node = tree.create(found.dir, found.name, .sym_link, 0o777) catch {
        return error.NoSpaceLeft;
    };
    node.data.appendSlice(tree.allocator(), target) catch {
        return error.NoSpaceLeft;
    };
}

// Reads where a symbolic link points. A target longer than the buffer is cut, as the real call does.
fn readLink(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, buffer: []u8) Dir.ReadLinkError!usize {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirReadLink(userdata, dir, sub_path, buffer);
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (faults.failWith(.link, Dir.ReadLinkError, &.{ "read_a_link_that_is_not_a_link", "read_a_link_that_is_missing" })) |err| {
        return err;
    }
    const found = tree.resolve(start, sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Dir.ReadLinkError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind != .sym_link) {
        return error.NotLink;
    }
    const length = @min(buffer.len, node.data.items.len);
    @memcpy(buffer[0..length], node.data.items[0..length]);
    return length;
}

// Gives a second name to a node.
fn linkNode(comptime Set: type, node: *Node, new_start: *Node, new_sub_path: []const u8) Set!void {
    const target = tree.resolve(new_start, new_sub_path, .{ .follow_last = false, .inject = true }) catch |err| {
        return narrow(Set, err);
    };
    if (target.node != null or isDotName(target.name) or target.name.len == 0) {
        return error.PathAlreadyExists;
    }
    if (node.kind == .directory) {
        return error.PermissionDenied;
    }
    if (!target.dir.mayWrite() or !target.dir.maySearch()) {
        return error.AccessDenied;
    }
    tree.attach(target.dir, target.name, node) catch {
        return error.NoSpaceLeft;
    };
}

// The ids of the rows for a call that makes a hard link.
const hard_link_ids = make_link_ids ++ [_][]const u8{"hard_link_across_filesystems"};

// Makes a second name for the node at the first name.
fn hardLinkByPath(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
    options: Dir.HardLinkOptions,
) Dir.HardLinkError!void {
    if (!isSimulatedDirHandle(old_dir.handle) and !isSimulatedDirHandle(new_dir.handle)) {
        return underneath.vtable.dirHardLink(userdata, old_dir, old_sub_path, new_dir, new_sub_path, options);
    }
    if (!isSimulatedDirHandle(old_dir.handle) or !isSimulatedDirHandle(new_dir.handle)) {
        return error.CrossDevice;
    }
    if (faults.failWith(.link, Dir.HardLinkError, &hard_link_ids)) |err| {
        return err;
    }
    const old_start = startOf(old_dir) orelse {
        return error.FileNotFound;
    };
    const new_start = startOf(new_dir) orelse {
        return error.FileNotFound;
    };
    const found = tree.resolve(old_start, old_sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(Dir.HardLinkError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    return linkNode(Dir.HardLinkError, node, new_start, new_sub_path);
}

// Makes a second name for an open file.
fn hardLinkOpenFile(userdata: ?*anyopaque, file: File, new_dir: Dir, new_sub_path: []const u8, options: File.HardLinkOptions) File.HardLinkError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileHardLink(userdata, file, new_dir, new_sub_path, options);
    }
    if (!isSimulatedDirHandle(new_dir.handle)) {
        return error.CrossDevice;
    }
    if (faults.failWith(.link, File.HardLinkError, &hard_link_ids)) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.FileNotFound;
    };
    const new_start = startOf(new_dir) orelse {
        return error.FileNotFound;
    };
    return linkNode(File.HardLinkError, open.node, new_start, new_sub_path);
}

// Changes the permission bits of an open directory.
fn setDirPermissions(userdata: ?*anyopaque, dir: Dir, permissions: Dir.Permissions) Dir.SetPermissionsError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirSetPermissions(userdata, dir, permissions);
    }
    if (faults.failWith(.attributes, Dir.SetPermissionsError, &attribute_ids)) |err| {
        return err;
    }
    const node = startOf(dir) orelse {
        return error.FileNotFound;
    };
    changeMode(node, permissions);
}

// Changes the permission bits of what a name refers to.
fn setPermissionsByPath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: File.Permissions,
    options: Dir.SetFilePermissionsOptions,
) Dir.SetFilePermissionsError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirSetFilePermissions(userdata, dir, sub_path, permissions, options);
    }
    if (faults.failWith(.attributes, Dir.SetFilePermissionsError, &attribute_ids)) |err| {
        return err;
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(Dir.SetFilePermissionsError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind == .sym_link) {
        return error.OperationUnsupported;
    }
    changeMode(node, permissions);
}

// Changes the permission bits of an open file.
fn setFilePermissions(userdata: ?*anyopaque, file: File, permissions: File.Permissions) File.SetPermissionsError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSetPermissions(userdata, file, permissions);
    }
    if (faults.failWith(.attributes, File.SetPermissionsError, &attribute_ids)) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.FileNotFound;
    };
    changeMode(open.node, permissions);
}

// Sets the permission bits of a node.
fn changeMode(node: *Node, permissions: File.Permissions) void {
    node.mode = permissions.toMode() & 0o7777;
    node.changed = tree.now();
}

// Changes the owner and group of an open directory.
fn setDirOwner(userdata: ?*anyopaque, dir: Dir, owner: ?File.Uid, group: ?File.Gid) Dir.SetOwnerError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirSetOwner(userdata, dir, owner, group);
    }
    if (faults.failWith(.attributes, Dir.SetOwnerError, &attribute_ids)) |err| {
        return err;
    }
    const node = startOf(dir) orelse {
        return error.FileNotFound;
    };
    changeOwner(node, owner, group);
}

// Changes the owner and group of what a name refers to.
fn setOwnerByPath(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    owner: ?File.Uid,
    group: ?File.Gid,
    options: Dir.SetFileOwnerOptions,
) Dir.SetFileOwnerError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirSetFileOwner(userdata, dir, sub_path, owner, group, options);
    }
    if (faults.failWith(.attributes, Dir.SetFileOwnerError, &attribute_ids)) |err| {
        return err;
    }
    const start = startOf(dir) orelse {
        return error.FileNotFound;
    };
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return narrow(Dir.SetFileOwnerError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    changeOwner(node, owner, group);
}

// Changes the owner and group of an open file.
fn setFileOwner(userdata: ?*anyopaque, file: File, owner: ?File.Uid, group: ?File.Gid) File.SetOwnerError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSetOwner(userdata, file, owner, group);
    }
    if (faults.failWith(.attributes, File.SetOwnerError, &attribute_ids)) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.FileNotFound;
    };
    changeOwner(open.node, owner, group);
}

// Sets the owner and group of a node. A null leaves that one as it was.
fn changeOwner(node: *Node, owner: ?File.Uid, group: ?File.Gid) void {
    if (owner) |uid| {
        node.owner = uid;
    }
    if (group) |gid| {
        node.group = gid;
    }
    node.changed = tree.now();
}

// Sets the times of a node. The change time is always now, as on a real filesystem.
fn changeTimes(node: *Node, accessed: File.SetTimestamp, modified: File.SetTimestamp) void {
    switch (accessed) {
        .unchanged => {},
        .now => {
            node.accessed = tree.now();
        },
        .new => |stamp| {
            node.accessed = stamp;
        },
    }
    switch (modified) {
        .unchanged => {},
        .now => {
            node.modified = tree.now();
        },
        .new => |stamp| {
            node.modified = stamp;
        },
    }
    node.changed = tree.now();
}

// Sets the times of what a name refers to.
fn setTimestampsByPath(userdata: ?*anyopaque, dir: Dir, sub_path: []const u8, options: Dir.SetTimestampsOptions) Dir.SetTimestampsError!void {
    if (!isSimulatedDirHandle(dir.handle)) {
        return underneath.vtable.dirSetTimestamps(userdata, dir, sub_path, options);
    }
    if (faults.failWith(.attributes, Dir.SetTimestampsError, &attribute_ids)) |err| {
        return err;
    }
    // This call's error set has no word for a missing path and Zig's own implementation reports
    // one as `Unexpected`, so that is what a missing path or a path that cannot be searched is.
    const start = startOf(dir) orelse {
        return error.Unexpected;
    };
    const found = tree.resolve(start, sub_path, .{ .follow_last = options.follow_symlinks, .inject = true }) catch |err| {
        return switch (err) {
            error.AccessDenied => error.AccessDenied,
            error.NameTooLong => error.NameTooLong,
            else => error.Unexpected,
        };
    };
    const node = found.node orelse {
        return error.Unexpected;
    };
    changeTimes(node, options.access_timestamp, options.modify_timestamp);
}

// Sets the times of an open file.
fn setTimestamps(userdata: ?*anyopaque, file: File, options: File.SetTimestampsOptions) File.SetTimestampsError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSetTimestamps(userdata, file, options);
    }
    if (faults.failWith(.attributes, File.SetTimestampsError, &attribute_ids)) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.Unexpected;
    };
    changeTimes(open.node, options.access_timestamp, options.modify_timestamp);
}

// Lets go of files.
fn closeFiles(userdata: ?*anyopaque, closing: []const File) void {
    for (closing) |file| {
        if (!isSimulatedFileHandle(file.handle)) {
            underneath.vtable.fileClose(userdata, &.{file});
            continue;
        }
        if (file.handle >= first_handle) {
            if (openOf(file.handle)) |found| {
                found.is_open = false;
                found.lock = .none;
            }
        }
    }
}

// What an open file is.
fn statOpenFile(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileStat(userdata, file);
    }
    if (faults.failWith(.file_state, File.StatError, &.{"length_cannot_be_read"})) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.Unexpected;
    };
    return statOf(open.node);
}

// How many bytes an open file holds.
fn lengthOf(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileLength(userdata, file);
    }
    if (faults.failWith(.file_state, File.LengthError, &.{"length_cannot_be_read"})) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.Unexpected;
    };
    return statOf(open.node).size;
}

// How many bytes the pieces of a write hold, counting the last piece `splat` times.
fn totalBytes(header: []const u8, data: []const []const u8, splat: usize) usize {
    var total = header.len;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |piece| {
            total += piece.len;
        }
        total += data[data.len - 1].len * splat;
    }
    return total;
}

// Writes `bytes` into a node at `at`, growing it first, with zeros in any gap.
fn putBytes(node: *Node, at: u64, bytes: []const u8) error{NoSpaceLeft}!void {
    if (bytes.len == 0) {
        return;
    }
    const start = std.math.cast(usize, at) orelse {
        return error.NoSpaceLeft;
    };
    const end = std.math.add(usize, start, bytes.len) catch {
        return error.NoSpaceLeft;
    };
    if (end > node.data.items.len) {
        try tree.resizeData(node, end);
    }
    @memcpy(node.data.items[start..end], bytes);
    const stamp = tree.now();
    node.modified = stamp;
    node.changed = stamp;
}

// Where the pieces of one write go and how many bytes of them have gone.
const Sink = struct {
    // The node written to.
    node: *Node,

    // Where the first byte lands.
    at: u64,

    // How many bytes have been written.
    written: usize = 0,

    // The most bytes to write, which is less than everything on a short write.
    limit: usize,

    // Writes as much of `bytes` as the limit allows and says whether all of it went. A failure
    // after some bytes went is not reported: the bytes that went are and the next call fails.
    fn put(self: *Sink, bytes: []const u8) error{NoSpaceLeft}!bool {
        const taking = @min(bytes.len, self.limit - self.written);
        putBytes(self.node, self.at + self.written, bytes[0..taking]) catch |err| {
            if (self.written > 0) {
                return false;
            }
            return err;
        };
        self.written += taking;
        return taking == bytes.len;
    }
};

// Writes a header and the pieces of a write into a node, stopping at `limit`.
fn writePieces(node: *Node, at: u64, header: []const u8, data: []const []const u8, splat: usize, limit: usize) error{NoSpaceLeft}!usize {
    var sink: Sink = .{ .node = node, .at = at, .limit = limit };
    if (!try sink.put(header)) {
        return sink.written;
    }
    for (data, 0..) |piece, index| {
        const times = if (index == data.len - 1) splat else 1;
        var again: usize = 0;
        while (again < times) : (again += 1) {
            if (!try sink.put(piece)) {
                return sink.written;
            }
        }
    }
    return sink.written;
}

// How many bytes a short write accepts out of `total`: some, but fewer than all.
fn shortCount(total: usize) usize {
    return @max(1, total / 2);
}

// Writes bytes at a position of an open file.
fn writePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileWritePositional(userdata, file, header, data, splat, offset);
    }
    const open = openOf(file.handle) orelse {
        return error.NotOpenForWriting;
    };
    if (open.node.kind == .character_device) {
        return error.Unseekable;
    }
    if (faults.failWith(.file_state, File.WritePositionalError, &stream_state_ids)) |err| {
        return err;
    }
    const total = totalBytes(header, data, splat);
    var limit = total;
    const picked = if (total >= 2)
        faults.ask(.write, File.WritePositionalError, &write_short_ids)
    else
        faults.ask(.write, File.WritePositionalError, &write_ids);
    if (picked) |kind| {
        if (faults.isKind(.write, "short_write", kind)) {
            limit = shortCount(total);
        } else {
            return faults.errorOf(.write, File.WritePositionalError, kind);
        }
    }
    if (!open.writable or open.node.kind == .directory) {
        return error.NotOpenForWriting;
    }
    return writePieces(open.node, offset, header, data, splat, limit) catch {
        return error.NoSpaceLeft;
    };
}

// Copies from a reader into an open file, one chunk a call.
fn copyInto(
    comptime Set: type,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: std.Io.Limit,
    at: u64,
    streaming: bool,
) Set!usize {
    const open = openOf(file.handle) orelse {
        return error.NotOpenForWriting;
    };
    if (open.copied > 0) {
        if (faults.ask(.rename_copy, error{}, &.{"copy_fails_part_way_through"})) |_| {
            file_reader.err = error.InputOutput;
            return error.ReadFailed;
        }
    }
    if (!open.writable or open.node.kind == .directory) {
        return error.NotOpenForWriting;
    }
    var chunk: [copy_chunk_bytes]u8 = undefined;
    const wanted = limit.minInt(chunk.len);
    const got = file_reader.interface.readSliceShort(chunk[0..wanted]) catch {
        return error.ReadFailed;
    };
    if (got == 0 and header.len == 0) {
        return error.EndOfStream;
    }
    const position = if (streaming) open.position else at;
    const at_end = if (open.node.kind == .character_device) open.node.data.items.len else position;
    const pieces = [_][]const u8{chunk[0..got]};
    const written = writePieces(open.node, at_end, header, &pieces, 1, header.len + got) catch {
        return error.NoSpaceLeft;
    };
    open.copied += written;
    if (streaming) {
        open.position += written;
    }
    return written;
}

// Copies from a reader into an open file at a position, which is what a file copy does.
fn writeFilePositional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: std.Io.Limit,
    offset: u64,
) File.WriteFilePositionalError!usize {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileWriteFilePositional(userdata, file, header, file_reader, limit, offset);
    }
    if (openOf(file.handle)) |open| {
        if (open.node.kind == .character_device) {
            return error.Unseekable;
        }
    }
    return copyInto(File.WriteFilePositionalError, file, header, file_reader, limit, offset, false);
}

// Copies from a reader into an open file at its current position.
fn writeFileStreaming(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    file_reader: *File.Reader,
    limit: std.Io.Limit,
) File.Writer.WriteFileError!usize {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileWriteFileStreaming(userdata, file, header, file_reader, limit);
    }
    return copyInto(File.Writer.WriteFileError, file, header, file_reader, limit, 0, true);
}

// Reads into the buffers from a node at `offset`, taking at most `limit` bytes.
fn readPieces(node: *const Node, data: []const []u8, offset: u64, limit: usize) usize {
    const contents = node.data.items;
    var at = std.math.cast(usize, offset) orelse {
        return 0;
    };
    var copied: usize = 0;
    for (data) |into| {
        if (at >= contents.len or copied >= limit) {
            break;
        }
        const taking = @min(into.len, contents.len - at, limit - copied);
        @memcpy(into[0..taking], contents[at .. at + taking]);
        at += taking;
        copied += taking;
    }
    return copied;
}

// How many bytes a read of `data` at `offset` could give, which tells which failures can happen.
fn readableBytes(node: *const Node, data: []const []u8, offset: u64) usize {
    var capacity: usize = 0;
    for (data) |into| {
        capacity += into.len;
    }
    const at = std.math.cast(usize, offset) orelse {
        return 0;
    };
    if (at >= node.data.items.len) {
        return 0;
    }
    return @min(capacity, node.data.items.len - at);
}

// Reads bytes from a position of an open file. Giving back no bytes is how this call says the end
// of the file has been reached.
fn readPositional(userdata: ?*anyopaque, file: File, data: []const []u8, offset: u64) File.ReadPositionalError!usize {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileReadPositional(userdata, file, data, offset);
    }
    const open = openOf(file.handle) orelse {
        return error.NotOpenForReading;
    };
    if (open.node.kind == .character_device) {
        return error.Unseekable;
    }
    if (faults.failWith(.file_state, File.ReadPositionalError, &stream_state_ids)) |err| {
        return err;
    }
    const available = readableBytes(open.node, data, offset);

    // The set that can carry an early end of stream is wider than the call's own, because the
    // call says the end has come by giving back no bytes and not by an error.
    const AskSet = File.ReadPositionalError || error{EndOfStream};
    const picked = if (available >= 2)
        faults.ask(.read, AskSet, &read_short_ids)
    else if (available == 1)
        faults.ask(.read, AskSet, &read_early_ids)
    else
        faults.ask(.read, AskSet, &read_ids);
    var limit = available;
    if (picked) |kind| {
        if (faults.isKind(.read, "short_read", kind)) {
            limit = shortCount(available);
        } else if (faults.isKind(.read, "early_end_of_stream", kind)) {
            return 0;
        } else {
            return faults.errorOf(.read, File.ReadPositionalError, kind);
        }
    }
    if (!open.readable) {
        return error.NotOpenForReading;
    }
    if (open.node.kind == .directory) {
        return error.IsDir;
    }
    return readPieces(open.node, data, offset, limit);
}

// Moves the position of streaming reads and writes of an open file.
fn seekTo(userdata: ?*anyopaque, file: File, absolute_offset: u64) File.SeekError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSeekTo(userdata, file, absolute_offset);
    }
    if (faults.failWith(.file_state, File.SeekError, &.{"read_or_write_at_a_position_on_a_stream_that_cannot_seek"})) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.Unseekable;
    };
    if (open.node.kind == .character_device) {
        return error.Unseekable;
    }
    open.position = absolute_offset;
}

// Moves the position of streaming reads and writes of an open file by an amount.
fn seekBy(userdata: ?*anyopaque, file: File, relative_offset: i64) File.SeekError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSeekBy(userdata, file, relative_offset);
    }
    if (faults.failWith(.file_state, File.SeekError, &.{"read_or_write_at_a_position_on_a_stream_that_cannot_seek"})) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.Unseekable;
    };
    if (open.node.kind == .character_device) {
        return error.Unseekable;
    }
    const was: i64 = @intCast(open.position);
    const moved = std.math.add(i64, was, relative_offset) catch {
        return error.Unseekable;
    };
    if (moved < 0) {
        return error.Unseekable;
    }
    open.position = @intCast(moved);
}

// Asks for a flush of an open file. There is nothing behind the tree to flush to.
fn sync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSync(userdata, file);
    }
    if (faults.failWith(.file_state, File.SyncError, &.{ "sync_fails", "sync_out_of_space" })) |err| {
        return err;
    }
}

// Whether an open file is a terminal. None of these are.
fn isTty(userdata: ?*anyopaque, file: File) std.Io.Cancelable!bool {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileIsTty(userdata, file);
    }
    return false;
}

// Asks for escape codes to be enabled. None of these are terminals.
fn enableAnsiEscapeCodes(userdata: ?*anyopaque, file: File) File.EnableAnsiEscapeCodesError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileEnableAnsiEscapeCodes(userdata, file);
    }
    return error.NotTerminalDevice;
}

// Whether escape codes would be understood. None of these are terminals.
fn supportsAnsiEscapeCodes(userdata: ?*anyopaque, file: File) std.Io.Cancelable!bool {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSupportsAnsiEscapeCodes(userdata, file);
    }
    return false;
}

// Sets how many bytes an open file holds.
fn setLength(userdata: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileSetLength(userdata, file, length);
    }
    if (faults.failWith(.file_state, File.SetLengthError, &.{ "resize_past_the_size_limit", "file_cannot_be_resized" })) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.NonResizable;
    };
    if (open.node.kind != .file) {
        return error.NonResizable;
    }
    if (!open.writable) {
        return error.AccessDenied;
    }
    const wanted = std.math.cast(usize, length) orelse {
        return error.FileTooBig;
    };
    tree.resizeData(open.node, wanted) catch {
        return error.FileTooBig;
    };
}

// Takes an advisory lock on an open file.
fn lock(userdata: ?*anyopaque, file: File, wanted: File.Lock) File.LockError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileLock(userdata, file, wanted);
    }
    if (faults.failWith(.file_state, File.LockError, &.{ "locks_not_supported", "lock_out_of_resources" })) |err| {
        return err;
    }
    const open = openOf(file.handle) orelse {
        return error.SystemResources;
    };
    takeLock(open, wanted, false) catch unreachable;
}

// Tries to take an advisory lock on an open file and says whether it did.
fn tryLock(userdata: ?*anyopaque, file: File, wanted: File.Lock) File.LockError!bool {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileTryLock(userdata, file, wanted);
    }
    const picked = faults.ask(.file_state, File.LockError, &.{ "locks_not_supported", "lock_out_of_resources", "lock_already_held" });
    if (picked) |kind| {
        if (faults.isKind(.file_state, "lock_already_held", kind)) {
            return false;
        }
        return faults.errorOf(.file_state, File.LockError, kind);
    }
    const open = openOf(file.handle) orelse {
        return error.SystemResources;
    };
    if (isLockedByAnother(open, wanted)) {
        return false;
    }
    open.lock = wanted;
    return true;
}

// Lets go of the lock an open file holds.
fn unlock(userdata: ?*anyopaque, file: File) void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileUnlock(userdata, file);
    }
    if (openOf(file.handle)) |open| {
        open.lock = .none;
    }
}

// Turns an exclusive lock into a shared one without letting go.
fn downgradeLock(userdata: ?*anyopaque, file: File) File.DowngradeLockError!void {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileDowngradeLock(userdata, file);
    }
    if (openOf(file.handle)) |open| {
        open.lock = .shared;
    }
}

// Maps an open file into memory. Not simulated: the call is refused, as for a file that cannot be
// mapped.
fn createMemoryMap(userdata: ?*anyopaque, file: File, options: File.MemoryMap.CreateOptions) File.MemoryMap.CreateError!File.MemoryMap {
    if (!isSimulatedFileHandle(file.handle)) {
        return underneath.vtable.fileMemoryMapCreate(userdata, file, options);
    }
    return error.AccessDenied;
}

// Opens the program's own executable. The simulated tree does not hold it, so it is not found.
fn openExecutable(userdata: ?*anyopaque, options: Dir.OpenFileOptions) std.process.OpenExecutableError!File {
    _ = userdata;
    _ = options;
    return error.FileNotFound;
}

// The ids of the rows for a call that reads or changes the current directory.
const current_directory_ids = [_][]const u8{ "current_directory_was_deleted", "path_too_long" };

// The ids for reading the current directory into a buffer as large as any path. No path is too
// long for that buffer, and `std.process.currentPathAlloc` reads into one and treats the error as
// one that cannot happen, so it is not offered.
const current_directory_deleted_ids = [_][]const u8{"current_directory_was_deleted"};

// Writes the path of the current directory into `buffer`.
fn currentPath(userdata: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
    _ = userdata;
    prepare();
    const failure = if (buffer.len >= std.fs.max_path_bytes)
        faults.failWith(.current_directory, std.process.CurrentPathError, &current_directory_deleted_ids)
    else
        faults.failWith(.current_directory, std.process.CurrentPathError, &current_directory_ids);
    if (failure) |err| {
        return err;
    }
    const path = try tree.pathOf(tree.currentDirectory(), buffer) orelse {
        return error.CurrentDirUnlinked;
    };
    return path.len;
}

// Makes an open directory the current directory.
fn setCurrentDir(userdata: ?*anyopaque, dir: Dir) std.process.SetCurrentDirError!void {
    _ = userdata;
    if (faults.failWith(.current_directory, std.process.SetCurrentDirError, &current_directory_ids)) |err| {
        return err;
    }
    const node = startOf(dir) orelse {
        return error.FileNotFound;
    };
    if (node.unlinked) {
        return error.FileNotFound;
    }
    tree.setCurrentDirectory(node);
}

// Makes the directory at `path` the current directory.
fn setCurrentPath(userdata: ?*anyopaque, path: []const u8) std.process.SetCurrentPathError!void {
    _ = userdata;
    prepare();
    if (faults.failWith(.current_directory, std.process.SetCurrentPathError, &current_directory_ids)) |err| {
        return err;
    }
    const found = tree.resolve(tree.currentDirectory(), path, .{ .inject = true }) catch |err| {
        return narrow(std.process.SetCurrentPathError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind != .directory) {
        return error.NotDir;
    }
    if (!node.maySearch()) {
        return error.AccessDenied;
    }
    tree.setCurrentDirectory(node);
}

// Reads bytes of an open file at its current position, or of standard input.
fn readStreaming(asked: std.Io.Operation.FileReadStreaming) std.Io.Operation.FileReadStreaming.Result {
    const Set = std.Io.Operation.FileReadStreaming.Error;
    const open = openOf(asked.file.handle) orelse {
        return error.NotOpenForReading;
    };
    const node = open.node;
    var capacity: usize = 0;
    for (asked.data) |into| {
        capacity += into.len;
    }
    const available = readableBytes(node, asked.data, open.position);

    // Standard input has its own rows: it can be closed and a failure is an input error.
    if (node.kind == .character_device) {
        if (faults.ask(.standard_stream, Set, &.{ "input_closed", "input_or_output_error" })) |kind| {
            return faults.errorOf(.standard_stream, Set, kind);
        }
    } else {
        if (faults.failWith(.file_state, Set, &stream_state_ids)) |err| {
            return err;
        }
    }
    var limit = available;
    if (node.kind != .character_device) {
        const picked = if (available >= 2)
            faults.ask(.read, Set, &read_short_ids)
        else if (available == 1)
            faults.ask(.read, Set, &read_early_ids)
        else
            faults.ask(.read, Set, &read_ids);
        if (picked) |kind| {
            if (faults.isKind(.read, "short_read", kind)) {
                limit = shortCount(available);
            } else if (faults.isKind(.read, "early_end_of_stream", kind)) {
                return error.EndOfStream;
            } else {
                return faults.errorOf(.read, Set, kind);
            }
        }
    }
    if (!open.readable) {
        return error.NotOpenForReading;
    }
    if (node.kind == .directory) {
        return error.IsDir;
    }
    if (capacity == 0) {
        return 0;
    }
    if (available == 0) {
        return error.EndOfStream;
    }
    const copied = readPieces(node, asked.data, open.position, limit);
    open.position += copied;
    return copied;
}

// Writes bytes to an open file at its current position, or to standard output or error, which is
// the end of what has been written.
fn writeStreaming(asked: std.Io.Operation.FileWriteStreaming) std.Io.Operation.FileWriteStreaming.Result {
    const Set = std.Io.Operation.FileWriteStreaming.Error;
    const open = openOf(asked.file.handle) orelse {
        return error.NotOpenForWriting;
    };
    const node = open.node;
    const total = totalBytes(asked.header, asked.data, asked.splat);
    var limit = total;
    if (node.kind == .character_device) {
        const picked = if (total >= 2)
            faults.ask(.standard_stream, Set, &.{ "input_or_output_error", "output_closed", "short_write" })
        else
            faults.ask(.standard_stream, Set, &.{ "input_or_output_error", "output_closed" });
        if (picked) |kind| {
            if (faults.isKind(.standard_stream, "short_write", kind)) {
                limit = shortCount(total);
            } else {
                return faults.errorOf(.standard_stream, Set, kind);
            }
        }
        if (!open.writable) {
            return error.NotOpenForWriting;
        }
        return writePieces(node, node.data.items.len, asked.header, asked.data, asked.splat, limit) catch {
            return error.NoSpaceLeft;
        };
    }
    if (faults.failWith(.file_state, Set, &stream_state_ids)) |err| {
        return err;
    }
    const picked = if (total >= 2)
        faults.ask(.write, Set, &write_short_ids)
    else
        faults.ask(.write, Set, &write_ids);
    if (picked) |kind| {
        if (faults.isKind(.write, "short_write", kind)) {
            limit = shortCount(total);
        } else {
            return faults.errorOf(.write, Set, kind);
        }
    }
    if (!open.writable or node.kind == .directory) {
        return error.NotOpenForWriting;
    }
    const written = writePieces(node, open.position, asked.header, asked.data, asked.splat, limit) catch {
        return error.NoSpaceLeft;
    };
    open.position += written;
    return written;
}

// Performs one `Operation`. Reads and writes of files and of the standard streams are answered
// here. Everything else, such as a socket, goes underneath.
fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    switch (operation) {
        .file_read_streaming => |asked| {
            if (!isSimulatedFileHandle(asked.file.handle)) {
                return underneath.vtable.operate(userdata, operation);
            }
            return .{ .file_read_streaming = readStreaming(asked) };
        },
        .file_write_streaming => |asked| {
            if (!isSimulatedFileHandle(asked.file.handle)) {
                return underneath.vtable.operate(userdata, operation);
            }
            return .{ .file_write_streaming = writeStreaming(asked) };
        },
        else => {
            return underneath.vtable.operate(userdata, operation);
        },
    }
}

// Makes every submitted operation of `batch`, in the order submitted, and moves each to the
// completed list with its result.
fn runBatch(userdata: ?*anyopaque, batch: *std.Io.Batch) std.Io.Cancelable!void {
    var index = batch.submitted.head;
    while (index != .none) {
        const storage = &batch.storage[index.toIndex()];
        const next_index = storage.submission.node.next;
        const result = try operate(userdata, storage.submission.operation);
        storage.* = .{ .completion = .{ .node = .{ .next = .none }, .result = result } };
        switch (batch.completed.tail) {
            .none => batch.completed.head = index,
            else => |tail| batch.storage[tail.toIndex()].completion.node.next = index,
        }
        batch.completed.tail = index;
        index = next_index;
    }
    batch.submitted = .empty;
}

fn awaitBatchAsync(userdata: ?*anyopaque, batch: *std.Io.Batch) std.Io.Cancelable!void {
    return runBatch(userdata, batch);
}

fn awaitBatchConcurrent(userdata: ?*anyopaque, batch: *std.Io.Batch, _: std.Io.Timeout) std.Io.Batch.AwaitConcurrentError!void {
    return runBatch(userdata, batch);
}

// Closes a file this filesystem gave out, as `fileClose` does, for a caller that has no `Io` to
// close it through.
pub fn closeFile(file: File) void {
    closeFiles(null, &.{file});
}

// The read end of a pipe nothing ever writes to, open for reading: what a simulated child's
// output is. A read of it ends at once, as a real pipe's does once the child has exited.
pub fn openEmptyPipe() std.mem.Allocator.Error!File {
    prepare();
    const node = try tree.newNode(.named_pipe, 0o600);
    return .{ .handle = try newHandle(node, true, false), .flags = .{ .nonblocking = false } };
}

// Helpers for a scenario or an expectation function. They build and inspect the tree directly: they
// never ask the injector, never check permissions and never open a handle. A relative path starts at
// the current directory.

// The error a helper returns when something is not where it should be.
pub const HelperError = error{ FileNotFound, NotDir, IsDir, AccessDenied, SymLinkLoop, NameTooLong, PathAlreadyExists, OutOfMemory };

// Splits a path into the directory part and the last name.
fn splitPath(path: []const u8) struct { directory: []const u8, name: []const u8 } {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') {
        end -= 1;
    }
    const trimmed = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse {
        return .{ .directory = ".", .name = trimmed };
    };
    return .{ .directory = if (slash == 0) "/" else trimmed[0..slash], .name = trimmed[slash + 1 ..] };
}

// Makes a file holding `contents` and every directory above it. An existing file is replaced.
pub fn makeFile(path: []const u8, contents: []const u8) HelperError!void {
    prepare();
    const split = splitPath(path);
    const parent = try tree.makePath(tree.currentDirectory(), split.directory);
    const node = if (tree.lookup(parent, split.name)) |existing| blk: {
        if (existing.kind == .directory) {
            return error.IsDir;
        }
        break :blk existing;
    } else try tree.create(parent, split.name, .file, 0o644);
    tree.replaceData(node, contents) catch {
        return error.OutOfMemory;
    };
}

// Makes a directory and every directory above it.
pub fn makeDirectory(path: []const u8) HelperError!void {
    prepare();
    _ = try tree.makePath(tree.currentDirectory(), path);
}

// Makes a symbolic link at `link_path` that holds `target` and every directory above it. The
// target does not have to exist.
pub fn makeSymlink(target: []const u8, link_path: []const u8) HelperError!void {
    prepare();
    const split = splitPath(link_path);
    const parent = try tree.makePath(tree.currentDirectory(), split.directory);
    if (tree.lookup(parent, split.name) != null) {
        return error.PathAlreadyExists;
    }
    const node = try tree.create(parent, split.name, .sym_link, 0o777);
    try node.data.appendSlice(tree.allocator(), target);
}

// Finds the node at `path`, following links.
fn find(path: []const u8) ?*Node {
    prepare();
    const found = tree.resolve(tree.currentDirectory(), path, .{}) catch {
        return null;
    };
    return found.node;
}

// A copy of what a file holds, made with `allocator`. A link is followed.
pub fn readContents(allocator: std.mem.Allocator, path: []const u8) HelperError![]u8 {
    prepare();
    const found = tree.resolve(tree.currentDirectory(), path, .{}) catch |err| {
        return narrow(HelperError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind == .directory) {
        return error.IsDir;
    }
    return allocator.dupe(u8, node.data.items);
}

// Copies of the names inside a directory, in the order a listing gives them. Free them with
// `freeNames`.
pub fn listDirectory(allocator: std.mem.Allocator, path: []const u8) HelperError![][]u8 {
    prepare();
    const found = tree.resolve(tree.currentDirectory(), path, .{}) catch |err| {
        return narrow(HelperError, err);
    };
    const node = found.node orelse {
        return error.FileNotFound;
    };
    if (node.kind != .directory) {
        return error.NotDir;
    }
    var names: std.ArrayList([]u8) = .empty;
    errdefer freeNames(allocator, names.items);
    for (node.children.items) |child| {
        try names.append(allocator, try allocator.dupe(u8, child.name));
    }
    return names.toOwnedSlice(allocator);
}

// Frees what `listDirectory` returned.
pub fn freeNames(allocator: std.mem.Allocator, names: []const []u8) void {
    for (names) |name| {
        allocator.free(name);
    }
    allocator.free(names);
}

// Whether something is at `path`. A link is followed, so a dangling link is not there.
pub fn exists(path: []const u8) bool {
    return find(path) != null;
}

// What is at `path` without following a link at the last name, or null when nothing is.
pub fn kindOf(path: []const u8) ?File.Kind {
    prepare();
    const found = tree.resolve(tree.currentDirectory(), path, .{ .follow_last = false }) catch {
        return null;
    };
    const node = found.node orelse {
        return null;
    };
    return node.kind;
}

// Where the link at `link_path` points, or null when there is no link there. The text is the
// tree's own and stays valid until the next reset.
pub fn readSymlink(link_path: []const u8) ?[]const u8 {
    prepare();
    const found = tree.resolve(tree.currentDirectory(), link_path, .{ .follow_last = false }) catch {
        return null;
    };
    const node = found.node orelse {
        return null;
    };
    if (node.kind != .sym_link) {
        return null;
    }
    return node.data.items;
}

// Sets the permission bits of what is at `path`, following a link.
pub fn setMode(path: []const u8, mode: std.posix.mode_t) HelperError!void {
    const node = find(path) orelse {
        return error.FileNotFound;
    };
    node.mode = mode & 0o7777;
}

// Sets the modified time of what is at `path`, following a link.
pub fn setModifiedTime(path: []const u8, modified: std.Io.Timestamp) HelperError!void {
    const node = find(path) orelse {
        return error.FileNotFound;
    };
    node.modified = modified;
}

// Sets what standard input holds. Reading starts from its beginning.
pub fn setStandardInput(bytes: []const u8) HelperError!void {
    prepare();
    const node = standard_opens[0].node;
    node.data.clearRetainingCapacity();
    try node.data.appendSlice(tree.allocator(), bytes);
    standard_opens[0].position = 0;
}

// Everything written to standard output so far.
pub fn standardOutput() []const u8 {
    prepare();
    return standard_opens[1].node.data.items;
}

// Everything written to standard error so far.
pub fn standardError() []const u8 {
    prepare();
    return standard_opens[2].node.data.items;
}

test {
    _ = @import("filesystem.test.zig");
}
