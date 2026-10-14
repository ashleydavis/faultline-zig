// The tree the simulated filesystem keeps in memory: nodes for files, directories and symbolic links,
// the lookup of a path through that tree and the limits a real disk has.
//
// Nothing here knows about `std.Io`. The calls in `filesystem.zig` ask the injector, check what a
// call is allowed to do and then use this file to find and change nodes. There is no real disk
// behind any of it.
//
// The state is module-level so the `Io` the world hands out can reach it without a pointer and
// `reset` gives a fresh tree. Memory comes from one arena over the page allocator, so a reset frees
// the whole tree at once and a unit test that forgets to reset leaks nothing the test allocator
// would report.

const std = @import("std");
const faults = @import("filesystem_faults.zig");

const File = std.Io.File;

// How many bytes the whole simulated disk holds. A write past it is out of space. It is small
// because the tree lives in the memory of the process that runs the function under test and a
// function that writes in a loop must reach the end of the disk before it reaches the end of memory.
pub const capacity_bytes: u64 = 64 * 1024 * 1024;

// The most symbolic links one lookup follows before it gives up with a loop error. The same number
// Linux uses, so code that builds long chains of links meets the limit where it would on a real
// machine.
pub const max_symlink_hops: u32 = 40;

// The longest single name in a path, as on a real filesystem.
pub const max_name_bytes: usize = std.Io.Dir.max_name_bytes;

// The longest whole path, as on a real filesystem.
pub const max_path_bytes: usize = std.Io.Dir.max_path_bytes;

// One name inside a directory.
pub const Child = struct {
    // The name, without any slash.
    name: []const u8,

    // What the name refers to. Two names can refer to one node when a hard link was made.
    node: *Node,
};

// One file, directory or symbolic link.
pub const Node = struct {
    // A regular file, a directory, a symbolic link or (for the standard streams) a character device.
    kind: File.Kind,

    // A number that is different for every node, so two files can be told apart.
    inode: u64,

    // The permission bits. Only the owner bits are checked, because the simulated process owns
    // everything it makes.
    mode: std.posix.mode_t,

    // How many names refer to this node. Zero once the last one is removed.
    link_count: u32 = 0,

    // When the contents last changed.
    modified: std.Io.Timestamp,

    // When the node's own details last changed.
    changed: std.Io.Timestamp,

    // When the node was last read, when something set it. Null otherwise, as a real filesystem that
    // does not keep it up to date reports it.
    accessed: ?std.Io.Timestamp = null,

    // The owner, when something set one.
    owner: ?File.Uid = null,

    // The group, when something set one.
    group: ?File.Gid = null,

    // The contents of a file, or where a symbolic link points. Empty for a directory.
    data: std.ArrayList(u8) = .empty,

    // The names inside a directory, always sorted by name so a listing comes back in one fixed order.
    children: std.ArrayList(Child) = .empty,

    // The directory the node was first named in. Null for the root.
    parent: ?*Node = null,

    // The name the node was first given in `parent`.
    name: []const u8 = "",

    // True once the last name is gone. A handle that still refers to it can still read and write.
    unlinked: bool = false,

    // Whether the owner may read the node.
    pub fn mayRead(self: *const Node) bool {
        return self.mode & 0o400 != 0;
    }

    // Whether the owner may write the node, or add and remove names when it is a directory.
    pub fn mayWrite(self: *const Node) bool {
        return self.mode & 0o200 != 0;
    }

    // Whether the owner may search the node when it is a directory.
    pub fn maySearch(self: *const Node) bool {
        return self.mode & 0o100 != 0;
    }
};

// The memory every node, name and file content comes from.
var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// The top of the tree, or null before the first use.
var root_node: ?*Node = null;

// The directory a relative path starts from.
var current_node: ?*Node = null;

// The number the next node is given as its inode.
var next_inode: u64 = 1;

// How many bytes the files in the tree hold, to compare with `capacity_bytes`.
var used_bytes: u64 = 0;

// The memory for everything in the tree.
pub fn allocator() std.mem.Allocator {
    return arena_state.allocator();
}

// Throws the tree away and starts a new one holding only an empty root, which is also the current
// directory.
pub fn reset() void {
    _ = arena_state.reset(.free_all);
    next_inode = 1;
    used_bytes = 0;
    root_node = null;
    current_node = null;
    _ = root();
}

// The top of the tree. Made on first use.
pub fn root() *Node {
    if (root_node) |existing| {
        return existing;
    }
    const made = newNode(.directory, 0o755) catch {
        @panic("faultline: out of memory making the simulated filesystem");
    };
    made.link_count = 1;
    root_node = made;
    current_node = made;
    return made;
}

// The directory relative paths start from.
pub fn currentDirectory() *Node {
    _ = root();
    return current_node.?;
}

// Makes `node` the directory relative paths start from.
pub fn setCurrentDirectory(node: *Node) void {
    current_node = node;
}

// The moment now on the real clock. The tree is in memory but a file's age is compared with the
// clock the code under test reads, so a fixed value would make every file look ancient.
pub fn now() std.Io.Timestamp {
    var spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &spec);
    return .{ .nanoseconds = @as(i96, spec.sec) * std.time.ns_per_s + spec.nsec };
}

// Makes a node that has no name yet.
pub fn newNode(kind: File.Kind, mode: std.posix.mode_t) std.mem.Allocator.Error!*Node {
    const node = try allocator().create(Node);
    const stamp = now();
    node.* = .{
        .kind = kind,
        .inode = next_inode,
        .mode = mode,
        .modified = stamp,
        .changed = stamp,
    };
    next_inode += 1;
    return node;
}

// Where `name` sits in the sorted children of `dir`, or where it would be inserted.
fn position(dir: *const Node, name: []const u8) struct { found: bool, index: usize } {
    var low: usize = 0;
    var high: usize = dir.children.items.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, dir.children.items[middle].name, name)) {
            .lt => {
                low = middle + 1;
            },
            .gt => {
                high = middle;
            },
            .eq => {
                return .{ .found = true, .index = middle };
            },
        }
    }
    return .{ .found = false, .index = low };
}

// The node called `name` inside `dir`, without following it when it is a link.
pub fn lookup(dir: *const Node, name: []const u8) ?*Node {
    const where = position(dir, name);
    if (!where.found) {
        return null;
    }
    return dir.children.items[where.index].node;
}

// Gives `node` the name `name` inside `dir`. The name must not be taken. The first name a node gets
// is the one its path is built from.
pub fn attach(dir: *Node, name: []const u8, node: *Node) std.mem.Allocator.Error!void {
    const where = position(dir, name);
    std.debug.assert(!where.found);
    const kept = try allocator().dupe(u8, name);
    try dir.children.insert(allocator(), where.index, .{ .name = kept, .node = node });
    if (node.link_count == 0) {
        node.parent = dir;
        node.name = kept;
    }
    node.link_count += 1;
    node.unlinked = false;
    const stamp = now();
    dir.modified = stamp;
    dir.changed = stamp;
    node.changed = stamp;
}

// Removes the name `name` from `dir` and returns the node it referred to. The caller decides what
// to release when that was the last name.
pub fn detach(dir: *Node, name: []const u8) *Node {
    const where = position(dir, name);
    std.debug.assert(where.found);
    const node = dir.children.orderedRemove(where.index).node;
    node.link_count -= 1;
    if (node.link_count == 0) {
        node.unlinked = true;
    }
    const stamp = now();
    dir.modified = stamp;
    dir.changed = stamp;
    node.changed = stamp;
    return node;
}

// Gives the bytes a removed file held back to the disk.
pub fn release(node: *const Node) void {
    if (node.link_count == 0 and node.kind == .file) {
        used_bytes -= node.data.items.len;
    }
}

// Makes a node and names it `name` inside `dir`.
pub fn create(dir: *Node, name: []const u8, kind: File.Kind, mode: std.posix.mode_t) std.mem.Allocator.Error!*Node {
    const node = try newNode(kind, mode);
    try attach(dir, name, node);
    return node;
}

// Whether `bytes` more bytes fit on the disk.
pub fn hasRoomFor(bytes: u64) bool {
    return used_bytes + bytes <= capacity_bytes;
}

// Sets the length of a file, filling new bytes with zeros. Fails when the disk is full.
pub fn resizeData(node: *Node, length: usize) error{NoSpaceLeft}!void {
    const was = node.data.items.len;
    if (length > was and !hasRoomFor(length - was)) {
        return error.NoSpaceLeft;
    }
    node.data.resize(allocator(), length) catch {
        return error.NoSpaceLeft;
    };
    if (length > was) {
        @memset(node.data.items[was..length], 0);
        used_bytes += length - was;
    } else {
        used_bytes -= was - length;
    }
    const stamp = now();
    node.modified = stamp;
    node.changed = stamp;
}

// Replaces what a file holds with `bytes`.
pub fn replaceData(node: *Node, bytes: []const u8) error{NoSpaceLeft}!void {
    try resizeData(node, bytes.len);
    @memcpy(node.data.items, bytes);
}

// How many bytes the files in the tree hold.
pub fn usedBytes() u64 {
    return used_bytes;
}

// The errors a lookup can end in. They are all errors every call that takes a path can return.
pub const ResolveError = error{ FileNotFound, NotDir, AccessDenied, SymLinkLoop, NameTooLong };

// How a lookup treats the last name of the path.
pub const ResolveOptions = struct {
    // Whether a link at the last name is followed to what it points at.
    follow_last: bool = true,

    // Whether following a link asks the injector whether the link is dangling or loops. Calls the
    // code under test makes ask. Helpers a scenario uses to build and read the tree do not.
    inject: bool = false,
};

// Where a lookup ended.
pub const Resolved = struct {
    // The directory the last name is in.
    dir: *Node,

    // The last name. "." or ".." when the path ended that way and empty when it was only slashes.
    name: []const u8,

    // What the last name refers to, or null when nothing has that name yet.
    node: ?*Node,
};

// Finds `path` starting from `start` (an absolute path starts at the root). Every directory passed
// through has to allow searching and every link along the way is followed. A link at the last
// name is followed only when `options` says so.
pub fn resolve(start: *Node, path: []const u8, options: ResolveOptions) ResolveError!Resolved {
    var hops: u32 = 0;
    return resolveCounting(start, path, options, &hops);
}

// `resolve`, with the number of links followed so far shared across the links it follows.
fn resolveCounting(start: *Node, path: []const u8, options: ResolveOptions, hops: *u32) ResolveError!Resolved {
    if (path.len == 0) {
        return error.FileNotFound;
    }
    if (path.len >= max_path_bytes) {
        return error.NameTooLong;
    }
    var current = if (path[0] == '/') root() else start;
    if (current.unlinked) {
        return error.FileNotFound;
    }
    const trailing_slash = path[path.len - 1] == '/';
    var names = std.mem.tokenizeScalar(u8, path, '/');
    var name = names.next() orelse {
        return .{ .dir = current, .name = "", .node = current };
    };
    while (true) {
        const following = names.next();
        const is_last = following == null;
        if (name.len > max_name_bytes) {
            return error.NameTooLong;
        }
        if (std.mem.eql(u8, name, ".")) {
            if (is_last) {
                return .{ .dir = current.parent orelse current, .name = ".", .node = current };
            }
            name = following.?;
            continue;
        }
        if (std.mem.eql(u8, name, "..")) {
            current = current.parent orelse current;
            if (is_last) {
                return .{ .dir = current.parent orelse current, .name = "..", .node = current };
            }
            name = following.?;
            continue;
        }
        if (!current.maySearch()) {
            return error.AccessDenied;
        }
        const found = lookup(current, name);
        if (is_last and !trailing_slash) {
            const link = found orelse {
                return .{ .dir = current, .name = name, .node = null };
            };
            if (link.kind != .sym_link or !options.follow_last) {
                return .{ .dir = current, .name = name, .node = link };
            }
            return followLink(current, link, options, hops);
        }
        var target = found orelse {
            return error.FileNotFound;
        };
        if (target.kind == .sym_link) {
            const through = try followLink(current, target, options, hops);
            target = through.node orelse {
                return error.FileNotFound;
            };
        }
        if (target.kind != .directory) {
            return error.NotDir;
        }
        if (is_last) {
            return .{ .dir = current, .name = name, .node = target };
        }
        current = target;
        name = following.?;
    }
}

// Finds what the link `link`, which is in `dir`, points at. A link whose target is a name that is
// not there yet comes back with no node and the place the name would be, which is where opening it
// to create a file puts the file.
fn followLink(dir: *Node, link: *Node, options: ResolveOptions, hops: *u32) ResolveError!Resolved {
    hops.* += 1;
    if (hops.* > max_symlink_hops) {
        return error.SymLinkLoop;
    }
    if (options.inject) {
        if (faults.ask(.link, ResolveError, &.{ "dangling_link", "link_loop" })) |picked| {
            if (faults.isKind(.link, "dangling_link", picked)) {
                return error.FileNotFound;
            }
            return error.SymLinkLoop;
        }
    }
    return resolveCounting(dir, link.data.items, .{ .follow_last = true, .inject = options.inject }, hops);
}

// Makes every directory in `path`, as `mkdir -p` does and returns the last. Existing directories
// and links to directories are used as they are. Permissions are not checked: this is for building
// a tree, not for the code under test.
pub fn makePath(start: *Node, path: []const u8) !*Node {
    var current = if (path.len > 0 and path[0] == '/') root() else start;
    var names = std.mem.tokenizeScalar(u8, path, '/');
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, ".")) {
            continue;
        }
        if (std.mem.eql(u8, name, "..")) {
            current = current.parent orelse current;
            continue;
        }
        if (lookup(current, name)) |existing| {
            const found = try followAll(current, existing);
            if (found.kind != .directory) {
                return error.NotDir;
            }
            current = found;
        } else {
            current = try create(current, name, .directory, 0o755);
        }
    }
    return current;
}

// Follows links from `node`, which is in `dir`, until something that is not a link, or fails.
fn followAll(dir: *Node, node: *Node) !*Node {
    if (node.kind != .sym_link) {
        return node;
    }
    const resolved = try resolve(dir, node.data.items, .{});
    return resolved.node orelse error.FileNotFound;
}

// The absolute path of a node, written into `out`. Null when the node has been removed from the
// tree, so there is no path to it and an error when the buffer is too small.
pub fn pathOf(node: *const Node, out: []u8) error{NameTooLong}!?[]const u8 {
    const top = root();
    var length: usize = 0;
    var walking: *const Node = node;
    while (walking != top) {
        if (walking.unlinked) {
            return null;
        }
        length += 1 + walking.name.len;
        walking = walking.parent orelse {
            return null;
        };
    }
    if (length == 0) {
        length = 1;
    }
    if (length > out.len) {
        return error.NameTooLong;
    }
    if (node == top) {
        out[0] = '/';
        return out[0..1];
    }
    var end = length;
    walking = node;
    while (walking != top) {
        end -= walking.name.len;
        @memcpy(out[end .. end + walking.name.len], walking.name);
        end -= 1;
        out[end] = '/';
        walking = walking.parent.?;
    }
    return out[0..length];
}

test {
    _ = @import("filesystem_tree.test.zig");
}
