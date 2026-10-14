// Splits the work of one pass into shards that workers can run at the same time.
//
// A shard holds the work items of one file, so the calls of one function are never split between
// workers and one worker reads that file's conditions. The shards do not depend on how many workers
// run them, so a run with one worker and a run with many make the same shards, and the driver reads
// what the shards found in the order this returns them, so the report does not depend on which
// worker finished first.

const std = @import("std");
const worker = @import("worker.zig");

// The items of `items` grouped into shards, one per file in `files`, which holds the file of each
// item at the same index. Within a shard the items keep the order they had in `items`, and the
// shards are in the order of their first items. Everything returned is allocated from `allocator`.
pub fn split(allocator: std.mem.Allocator, items: []const worker.WorkItem, files: []const []const u8) ![]const []const worker.WorkItem {
    std.debug.assert(items.len == files.len);
    var shard_files: std.ArrayList([]const u8) = .empty;
    defer shard_files.deinit(allocator);
    var shards: std.ArrayList(std.ArrayList(worker.WorkItem)) = .empty;
    defer shards.deinit(allocator);

    for (items, files) |item, file| {
        const position = indexOf(shard_files.items, file) orelse blk: {
            try shard_files.append(allocator, file);
            try shards.append(allocator, .empty);
            break :blk shard_files.items.len - 1;
        };
        try shards.items[position].append(allocator, item);
    }

    const result = try allocator.alloc([]const worker.WorkItem, shards.items.len);
    for (shards.items, 0..) |*shard, position| {
        result[position] = try shard.toOwnedSlice(allocator);
    }
    return result;
}

// Frees what `split` returned.
pub fn free(allocator: std.mem.Allocator, shards: []const []const worker.WorkItem) void {
    for (shards) |shard| {
        allocator.free(shard);
    }
    allocator.free(shards);
}

// Where `file` is in `files`, or null.
fn indexOf(files: []const []const u8, file: []const u8) ?usize {
    for (files, 0..) |one, position| {
        if (std.mem.eql(u8, one, file)) {
            return position;
        }
    }
    return null;
}

test {
    _ = @import("shards.test.zig");
}
