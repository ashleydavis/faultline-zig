// Tests for the in-memory tree: nodes, the order of names, the lookup of a path through links and
// the limits of the disk.

const std = @import("std");
const injector_mod = @import("injector.zig");
const faults = @import("filesystem_faults.zig");
const tree = @import("filesystem_tree.zig");

const testing = std.testing;

// Starts every test from an empty tree.
fn fresh() void {
    tree.reset();
    faults.injector = null;
}

test "reset leaves an empty root that is also the current directory" {
    fresh();
    try testing.expectEqual(std.Io.File.Kind.directory, tree.root().kind);
    try testing.expect(tree.root() == tree.currentDirectory());
    try testing.expectEqual(@as(usize, 0), tree.root().children.items.len);
    try testing.expectEqual(@as(u64, 0), tree.usedBytes());
}

test "reset throws away what was made" {
    fresh();
    _ = try tree.create(tree.root(), "a", .file, 0o644);
    tree.reset();
    try testing.expectEqual(@as(usize, 0), tree.root().children.items.len);
}

test "a node gets an inode no other node has" {
    fresh();
    const one = try tree.newNode(.file, 0o644);
    const two = try tree.newNode(.file, 0o644);
    try testing.expect(one.inode != two.inode);
    try testing.expect(one.inode != tree.root().inode);
}

test "attach keeps the names of a directory sorted and lookup finds each" {
    fresh();
    const dir = tree.root();
    for ([_][]const u8{ "m", "b", "z", "a", "Q" }) |name| {
        _ = try tree.create(dir, name, .file, 0o644);
    }
    const expected = [_][]const u8{ "Q", "a", "b", "m", "z" };
    for (dir.children.items, expected) |child, name| {
        try testing.expectEqualStrings(name, child.name);
        try testing.expect(tree.lookup(dir, name) == child.node);
    }
    try testing.expect(tree.lookup(dir, "missing") == null);
}

test "attach counts the names a node has and names it once for its path" {
    fresh();
    const dir = tree.root();
    const sub = try tree.create(dir, "sub", .directory, 0o755);
    const file = try tree.create(dir, "first", .file, 0o644);
    try testing.expectEqual(@as(u32, 1), file.link_count);
    try tree.attach(sub, "second", file);
    try testing.expectEqual(@as(u32, 2), file.link_count);
    try testing.expectEqualStrings("first", file.name);
    try testing.expect(file.parent.? == dir);
}

test "detach removes a name and marks the node removed when the last name goes" {
    fresh();
    const dir = tree.root();
    const file = try tree.create(dir, "a", .file, 0o644);
    try tree.attach(dir, "b", file);
    try testing.expect(tree.detach(dir, "a") == file);
    try testing.expect(!file.unlinked);
    try testing.expect(tree.detach(dir, "b") == file);
    try testing.expect(file.unlinked);
    try testing.expectEqual(@as(usize, 0), dir.children.items.len);
}

test "attaching a removed node again clears its removed mark" {
    fresh();
    const dir = tree.root();
    const file = try tree.create(dir, "a", .file, 0o644);
    _ = tree.detach(dir, "a");
    try tree.attach(dir, "b", file);
    try testing.expect(!file.unlinked);
    try testing.expectEqualStrings("b", file.name);
}

test "release gives the bytes of a removed file back and leaves a file that still has a name" {
    fresh();
    const dir = tree.root();
    const file = try tree.create(dir, "a", .file, 0o644);
    try tree.replaceData(file, "12345");
    try testing.expectEqual(@as(u64, 5), tree.usedBytes());
    tree.release(file);
    try testing.expectEqual(@as(u64, 5), tree.usedBytes());
    _ = tree.detach(dir, "a");
    tree.release(file);
    try testing.expectEqual(@as(u64, 0), tree.usedBytes());
}

test "resizeData grows with zeros, shrinks and counts the bytes" {
    fresh();
    const file = try tree.create(tree.root(), "a", .file, 0o644);
    try tree.replaceData(file, "abc");
    try tree.resizeData(file, 5);
    try testing.expectEqualSlices(u8, "abc\x00\x00", file.data.items);
    try testing.expectEqual(@as(u64, 5), tree.usedBytes());
    try tree.resizeData(file, 1);
    try testing.expectEqualSlices(u8, "a", file.data.items);
    try testing.expectEqual(@as(u64, 1), tree.usedBytes());
}

test "a file that does not fit on the disk is out of space and the disk is left as it was" {
    fresh();
    const file = try tree.create(tree.root(), "a", .file, 0o644);
    try testing.expect(tree.hasRoomFor(tree.capacity_bytes));
    try testing.expect(!tree.hasRoomFor(tree.capacity_bytes + 1));
    try testing.expectError(error.NoSpaceLeft, tree.resizeData(file, tree.capacity_bytes + 1));
    try testing.expectEqual(@as(usize, 0), file.data.items.len);
    try testing.expectEqual(@as(u64, 0), tree.usedBytes());
}

test "resolve finds a file by a relative path and by an absolute one" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    const file = try tree.create(sub, "f", .file, 0o644);
    const relative = try tree.resolve(tree.root(), "sub/f", .{});
    try testing.expect(relative.node.? == file);
    try testing.expect(relative.dir == sub);
    try testing.expectEqualStrings("f", relative.name);
    const absolute = try tree.resolve(sub, "/sub/f", .{});
    try testing.expect(absolute.node.? == file);
}

test "resolve starts at the directory it is given for a relative path" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    const file = try tree.create(sub, "f", .file, 0o644);
    const found = try tree.resolve(sub, "f", .{});
    try testing.expect(found.node.? == file);
    try testing.expect((try tree.resolve(tree.root(), "f", .{})).node == null);
}

test "resolve steps over dot and double slashes and goes up with dot dot" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    const file = try tree.create(tree.root(), "f", .file, 0o644);
    try testing.expect((try tree.resolve(sub, "./../f", .{})).node.? == file);
    try testing.expect((try tree.resolve(tree.root(), "sub//./../f", .{})).node.? == file);

    // Going up from the root stays at the root.
    try testing.expect((try tree.resolve(tree.root(), "../../f", .{})).node.? == file);
}

test "resolve of a path that ends in dot or dot dot gives the directory" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    const here = try tree.resolve(sub, ".", .{});
    try testing.expect(here.node.? == sub);
    try testing.expectEqualStrings(".", here.name);
    const up = try tree.resolve(sub, "..", .{});
    try testing.expect(up.node.? == tree.root());
    try testing.expectEqualStrings("..", up.name);
    const only_slashes = try tree.resolve(sub, "///", .{});
    try testing.expect(only_slashes.node.? == tree.root());
}

test "resolve says where a name that is not there would go" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    const found = try tree.resolve(tree.root(), "sub/new", .{});
    try testing.expect(found.node == null);
    try testing.expect(found.dir == sub);
    try testing.expectEqualStrings("new", found.name);
}

test "resolve refuses an empty path, a path through a file and a missing directory" {
    fresh();
    _ = try tree.create(tree.root(), "file", .file, 0o644);
    try testing.expectError(error.FileNotFound, tree.resolve(tree.root(), "", .{}));
    try testing.expectError(error.NotDir, tree.resolve(tree.root(), "file/below", .{}));
    try testing.expectError(error.FileNotFound, tree.resolve(tree.root(), "nowhere/below", .{}));
}

test "resolve with a trailing slash needs a directory" {
    fresh();
    _ = try tree.create(tree.root(), "file", .file, 0o644);
    _ = try tree.create(tree.root(), "dir", .directory, 0o755);
    try testing.expectError(error.NotDir, tree.resolve(tree.root(), "file/", .{}));
    try testing.expect((try tree.resolve(tree.root(), "dir/", .{})).node != null);
    try testing.expectError(error.FileNotFound, tree.resolve(tree.root(), "new/", .{}));
}

test "resolve refuses a name or a path that is too long" {
    fresh();
    const long_name = "n" ** (tree.max_name_bytes + 1);
    try testing.expectError(error.NameTooLong, tree.resolve(tree.root(), long_name, .{}));
    const long_path = "d/" ** (tree.max_path_bytes / 2 + 1);
    try testing.expectError(error.NameTooLong, tree.resolve(tree.root(), long_path, .{}));
}

test "resolve refuses to search a directory the owner may not search" {
    fresh();
    const closed = try tree.create(tree.root(), "closed", .directory, 0o600);
    _ = try tree.create(closed, "inside", .file, 0o644);
    try testing.expectError(error.AccessDenied, tree.resolve(tree.root(), "closed/inside", .{}));
}

test "resolve starting at a removed directory finds nothing for a relative path" {
    fresh();
    const gone = try tree.create(tree.root(), "gone", .directory, 0o755);
    _ = tree.detach(tree.root(), "gone");
    try testing.expectError(error.FileNotFound, tree.resolve(gone, "x", .{}));
    try testing.expect((try tree.resolve(gone, "/", .{})).node.? == tree.root());
}

// Makes a link named `name` in `dir` that holds `target`.
fn link(dir: *tree.Node, name: []const u8, target: []const u8) !*tree.Node {
    const node = try tree.create(dir, name, .sym_link, 0o777);
    try node.data.appendSlice(tree.allocator(), target);
    return node;
}

test "resolve follows a link at the last name unless told not to" {
    fresh();
    const file = try tree.create(tree.root(), "f", .file, 0o644);
    const pointer = try link(tree.root(), "pointer", "f");
    try testing.expect((try tree.resolve(tree.root(), "pointer", .{})).node.? == file);
    try testing.expect((try tree.resolve(tree.root(), "pointer", .{ .follow_last = false })).node.? == pointer);
}

test "resolve follows a link in the middle of a path whatever the options" {
    fresh();
    const real = try tree.create(tree.root(), "real", .directory, 0o755);
    const file = try tree.create(real, "f", .file, 0o644);
    _ = try link(tree.root(), "alias", "real");
    try testing.expect((try tree.resolve(tree.root(), "alias/f", .{ .follow_last = false })).node.? == file);
}

test "a relative link is followed from the directory the link is in and an absolute one from the root" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    const file = try tree.create(tree.root(), "f", .file, 0o644);
    _ = try link(sub, "up", "../f");
    _ = try link(sub, "abs", "/f");
    try testing.expect((try tree.resolve(tree.root(), "sub/up", .{})).node.? == file);
    try testing.expect((try tree.resolve(tree.root(), "sub/abs", .{})).node.? == file);
}

test "a link to a name that is not there gives the place the name would be" {
    fresh();
    _ = try link(tree.root(), "pointer", "target");
    const found = try tree.resolve(tree.root(), "pointer", .{});
    try testing.expect(found.node == null);
    try testing.expectEqualStrings("target", found.name);
}

test "a link in the middle of a path that points at nothing is not found" {
    fresh();
    _ = try link(tree.root(), "dangling", "nowhere");
    try testing.expectError(error.FileNotFound, tree.resolve(tree.root(), "dangling/x", .{}));
}

test "a link to a file in the middle of a path is not a directory" {
    fresh();
    _ = try tree.create(tree.root(), "f", .file, 0o644);
    _ = try link(tree.root(), "pointer", "f");
    try testing.expectError(error.NotDir, tree.resolve(tree.root(), "pointer/x", .{}));
}

test "links that return to themselves are a loop and a long chain is a loop at the limit" {
    fresh();
    _ = try link(tree.root(), "a", "b");
    _ = try link(tree.root(), "b", "a");
    try testing.expectError(error.SymLinkLoop, tree.resolve(tree.root(), "a", .{}));
    _ = try tree.create(tree.root(), "end", .file, 0o644);

    // The link named `c<n>` points at the one before it, so following `c<n>` follows n + 1 links.
    var previous: []const u8 = "end";
    for (0..tree.max_symlink_hops + 1) |index| {
        const text = try std.fmt.allocPrint(tree.allocator(), "c{d}", .{index});
        _ = try link(tree.root(), text, previous);
        previous = text;
    }
    const at_limit = try std.fmt.allocPrint(tree.allocator(), "c{d}", .{tree.max_symlink_hops - 1});
    try testing.expect((try tree.resolve(tree.root(), at_limit, .{})).node != null);
    const past_limit = try std.fmt.allocPrint(tree.allocator(), "c{d}", .{tree.max_symlink_hops});
    try testing.expectError(error.SymLinkLoop, tree.resolve(tree.root(), past_limit, .{}));
}

test "resolve asks the injector once for each link it follows and not for a path without one" {
    fresh();
    defer faults.injector = null;
    _ = try tree.create(tree.root(), "f", .file, 0o644);
    _ = try link(tree.root(), "one", "f");
    _ = try link(tree.root(), "two", "one");
    var inj = injector_mod.Injector.init(testing.allocator, &.{});
    defer inj.deinit();
    faults.injector = &inj;

    _ = try tree.resolve(tree.root(), "f", .{ .inject = true });
    try testing.expectEqual(@as(usize, 0), inj.recorded.items.len);
    _ = try tree.resolve(tree.root(), "two", .{ .inject = true });
    try testing.expectEqual(@as(usize, 2), inj.recorded.items.len);

    // A lookup that does not inject asks nothing.
    inj.reset();
    _ = try tree.resolve(tree.root(), "two", .{});
    try testing.expectEqual(@as(usize, 0), inj.recorded.items.len);
}

test "an injected dangling link makes a good link not found and an injected loop makes it a loop" {
    fresh();
    defer faults.injector = null;
    _ = try tree.create(tree.root(), "f", .file, 0o644);
    _ = try link(tree.root(), "one", "f");

    const dangling = [_]injector_mod.Injection{.{ .point = .{ .effect = .link, .occurrence = 0 }, .kind = faults.indexOf(.link, "dangling_link") }};
    var first = injector_mod.Injector.init(testing.allocator, &dangling);
    defer first.deinit();
    faults.injector = &first;
    try testing.expectError(error.FileNotFound, tree.resolve(tree.root(), "one", .{ .inject = true }));

    const looping = [_]injector_mod.Injection{.{ .point = .{ .effect = .link, .occurrence = 0 }, .kind = faults.indexOf(.link, "link_loop") }};
    var second = injector_mod.Injector.init(testing.allocator, &looping);
    defer second.deinit();
    faults.injector = &second;
    try testing.expectError(error.SymLinkLoop, tree.resolve(tree.root(), "one", .{ .inject = true }));
}

test "makePath makes every directory, uses ones that are there and follows a link to a directory" {
    fresh();
    const deep = try tree.makePath(tree.root(), "a/b/c");
    try testing.expectEqualStrings("c", deep.name);
    try testing.expect((try tree.makePath(tree.root(), "a/b/c")) == deep);
    _ = try link(tree.root(), "alias", "a");
    try testing.expect((try tree.makePath(tree.root(), "alias/b/c")) == deep);
    try testing.expect((try tree.makePath(deep, "../c")) == deep);
    try testing.expect((try tree.makePath(deep, "/a")) == tree.lookup(tree.root(), "a").?);
}

test "makePath refuses a file in the way" {
    fresh();
    _ = try tree.create(tree.root(), "file", .file, 0o644);
    try testing.expectError(error.NotDir, tree.makePath(tree.root(), "file/below"));
    _ = try link(tree.root(), "dangling", "nowhere");
    try testing.expectError(error.FileNotFound, tree.makePath(tree.root(), "dangling/below"));
}

test "pathOf writes the absolute path of a node" {
    fresh();
    const deep = try tree.makePath(tree.root(), "a/b");
    const file = try tree.create(deep, "f.txt", .file, 0o644);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("/", (try tree.pathOf(tree.root(), &buffer)).?);
    try testing.expectEqualStrings("/a/b", (try tree.pathOf(deep, &buffer)).?);
    try testing.expectEqualStrings("/a/b/f.txt", (try tree.pathOf(file, &buffer)).?);
}

test "pathOf has no path for a removed node and refuses a buffer that is too small" {
    fresh();
    const file = try tree.create(tree.root(), "f.txt", .file, 0o644);
    var tiny: [3]u8 = undefined;
    try testing.expectError(error.NameTooLong, tree.pathOf(file, &tiny));
    _ = tree.detach(tree.root(), "f.txt");
    var buffer: [64]u8 = undefined;
    try testing.expect((try tree.pathOf(file, &buffer)) == null);
}

test "the current directory can be moved and relative paths follow it" {
    fresh();
    const sub = try tree.create(tree.root(), "sub", .directory, 0o755);
    tree.setCurrentDirectory(sub);
    try testing.expect(tree.currentDirectory() == sub);
    tree.reset();
    try testing.expect(tree.currentDirectory() == tree.root());
}

test "permissions are read from the owner bits" {
    fresh();
    const node = try tree.newNode(.file, 0o000);
    try testing.expect(!node.mayRead() and !node.mayWrite() and !node.maySearch());
    node.mode = 0o400;
    try testing.expect(node.mayRead() and !node.mayWrite());
    node.mode = 0o200;
    try testing.expect(node.mayWrite() and !node.mayRead());
    node.mode = 0o100;
    try testing.expect(node.maySearch());
    node.mode = 0o077;
    try testing.expect(!node.mayRead() and !node.mayWrite() and !node.maySearch());
}

test "the clock the tree stamps nodes with is the real clock" {
    fresh();
    const before = tree.now();
    const node = try tree.newNode(.file, 0o644);
    const after = tree.now();
    try testing.expect(node.modified.nanoseconds >= before.nanoseconds);
    try testing.expect(node.modified.nanoseconds <= after.nanoseconds);
}
