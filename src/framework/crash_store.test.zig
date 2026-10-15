const std = @import("std");
const crash_store = @import("crash_store.zig");

// A throwaway directory with its absolute path, for the tests that write the file.
const Fixture = struct {
    // The directory, removed by `deinit`.
    directory: std.testing.TmpDir,

    // Its absolute path.
    root: []const u8,

    fn init() !Fixture {
        var directory = std.testing.tmpDir(.{});
        errdefer directory.cleanup();
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = try directory.dir.realPath(std.testing.io, &buffer);
        return .{ .directory = directory, .root = try std.testing.allocator.dupe(u8, buffer[0..length]) };
    }

    fn deinit(self: *Fixture) void {
        std.testing.allocator.free(self.root);
        self.directory.cleanup();
    }
};

test "tokensOf reads one token per line and skips blank lines and the spaces around a token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try crash_store.tokensOf(arena.allocator(), "src/a.zig:f;seed=1\n\n  src/b.zig:g;seed=2 \r\n");

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("src/a.zig:f;seed=1", tokens[0]);
    try std.testing.expectEqualStrings("src/b.zig:g;seed=2", tokens[1]);
}

test "withNew keeps the kept tokens first and adds each new token once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try crash_store.withNew(arena.allocator(), &.{ "a", "b" }, &.{ "b", "c", "c" });

    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("a", tokens[0]);
    try std.testing.expectEqualStrings("b", tokens[1]);
    try std.testing.expectEqualStrings("c", tokens[2]);
}

test "isAmong is true only when a token in the list names the same call" {
    try std.testing.expect(crash_store.isAmong(&.{ "a", "b" }, "b"));
    try std.testing.expect(!crash_store.isAmong(&.{ "a", "b" }, "c"));
    try std.testing.expect(!crash_store.isAmong(&.{}, "a"));
}

test "isSameCall leaves the seed out when no value was drawn from it" {
    try std.testing.expect(crash_store.isSameCall(
        "words.zig:firstWord;seed=1;values=b0,b1;fail=allocator#0/allocation_fails",
        "words.zig:firstWord;seed=2;values=b0,b1;fail=allocator#0/allocation_fails",
    ));
    try std.testing.expect(crash_store.isSameCall("a.zig:scenario;seed=1", "a.zig:scenario;seed=2"));
}

test "isSameCall compares the seed when a value was drawn from it" {
    try std.testing.expect(!crash_store.isSameCall(
        "a.zig:f;seed=1;values=s0",
        "a.zig:f;seed=2;values=s0",
    ));
    try std.testing.expect(crash_store.isSameCall("a.zig:f;seed=1;values=s0", "a.zig:f;seed=1;values=s0"));
}

test "isSameCall tells apart calls with other values, another failure or another function" {
    try std.testing.expect(!crash_store.isSameCall("a.zig:f;seed=1;values=b0", "a.zig:f;seed=1;values=b1"));
    try std.testing.expect(!crash_store.isSameCall(
        "a.zig:f;seed=1;values=b0;fail=allocator#0/allocation_fails",
        "a.zig:f;seed=1;values=b0;fail=allocator#1/allocation_fails",
    ));
    try std.testing.expect(!crash_store.isSameCall("a.zig:f;seed=1;values=b0", "a.zig:g;seed=1;values=b0"));
    try std.testing.expect(!crash_store.isSameCall("a.zig:f;seed=1;values=b0", "a.zig:f;seed=1;values=b0;fail=allocator#0/allocation_fails"));
}

test "withNew does not add a crash found again with a new seed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try crash_store.withNew(arena.allocator(), &.{"a.zig:f;seed=1;values=b0"}, &.{"a.zig:f;seed=9;values=b0"});

    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("a.zig:f;seed=1;values=b0", tokens[0]);
}

test "read of a file that does not exist holds no tokens" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try std.fs.path.join(arena.allocator(), &.{ fixture.root, "flt-crashes.txt" });

    const tokens = try crash_store.read(arena.allocator(), std.testing.io, path);

    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "write creates the directory and read gives back the tokens written" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try std.fs.path.join(arena.allocator(), &.{ fixture.root, "cache", "flt-crashes.txt" });

    try crash_store.write(arena.allocator(), std.testing.io, path, &.{ "src/a.zig:f;seed=1", "src/b.zig:g;seed=2" });
    const tokens = try crash_store.read(arena.allocator(), std.testing.io, path);

    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("src/a.zig:f;seed=1", tokens[0]);
    try std.testing.expectEqualStrings("src/b.zig:g;seed=2", tokens[1]);
}
