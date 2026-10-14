// Tests for threads: the four thread failures through `spawn` and through the concurrency entries
// of `Io`.

const std = @import("std");
const testing = std.testing;
const world_effects = @import("world_effects.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

var ran: u32 = 0;

fn work(amount: u32) void {
    ran += amount;
}

fn answer(value: u32) u32 {
    return value + 1;
}

fn groupWork(_: u32) void {}

test "a thread started with no failure runs to the end and can be joined" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    ran = 0;
    const thread = try world_effects.spawnThread(work, .{5});
    thread.join();
    try testing.expectEqual(@as(u32, 5), ran);
    try testing.expectEqual(@as(usize, 1), world.injector.recorded.items.len);
}

test "a thread can be detached" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    ran = 0;
    const thread = try world_effects.spawnThread(work, .{2});
    thread.detach();
    try testing.expectEqual(@as(u32, 2), ran);
}

test "a spawn returns error.ThreadQuotaExceeded when there are too many threads" {
    const plan = [_]injector_mod.Injection{failAt(.thread, 0, "too_many_threads")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    ran = 0;
    try testing.expectError(error.ThreadQuotaExceeded, world_effects.spawnThread(work, .{1}));
    try testing.expectEqual(@as(u32, 0), ran);
}

test "a spawn returns error.SystemResources when out of resources" {
    const plan = [_]injector_mod.Injection{failAt(.thread, 0, "out_of_resources")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.SystemResources, world_effects.spawnThread(work, .{1}));
}

test "a spawn returns error.OutOfMemory when memory runs out" {
    const plan = [_]injector_mod.Injection{failAt(.thread, 0, "out_of_memory")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.OutOfMemory, world_effects.spawnThread(work, .{1}));
}

test "a spawn returns error.LockedMemoryLimitExceeded when the locked memory limit is reached" {
    const plan = [_]injector_mod.Injection{failAt(.thread, 0, "locked_memory_limit_reached")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.LockedMemoryLimitExceeded, world_effects.spawnThread(work, .{1}));
}

test "a concurrent task returns error.ConcurrencyUnavailable for every thread failure" {
    const ids = [_]u8{ 0, 1, 2, 3 };
    for (ids) |kind| {
        const plan = [_]injector_mod.Injection{.{ .point = .{ .effect = .thread, .occurrence = 0 }, .kind = kind }};
        var world: World = undefined;
        world.start(&plan);
        defer world.stop();
        try testing.expectError(error.ConcurrencyUnavailable, world.io.concurrent(answer, .{1}));
    }
}

test "a concurrent task with no failure is handed to the Io underneath" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    // Whether the real implementation has a thread to give is its own answer, so the test checks
    // that the answer is the real one and that the call was recorded once.
    if (world.io.concurrent(answer, .{1})) |future| {
        var started = future;
        try testing.expectEqual(@as(u32, 2), started.await(world.io));
    } else |err| {
        try testing.expectEqual(error.ConcurrencyUnavailable, err);
    }
    try testing.expectEqual(@as(usize, 1), world.injector.recorded.items.len);
}

test "a concurrent task in a group returns error.ConcurrencyUnavailable when a thread failure is planned" {
    const plan = [_]injector_mod.Injection{failAt(.thread, 0, "out_of_resources")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var group: std.Io.Group = .init;
    try testing.expectError(error.ConcurrencyUnavailable, group.concurrent(world.io, groupWork, .{1}));
}

test "an async task is not asked of the injector because it cannot fail" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var future = world.io.async(answer, .{1});
    try testing.expectEqual(@as(u32, 2), future.await(world.io));
    try testing.expectEqual(@as(usize, 0), world.injector.recorded.items.len);
}
