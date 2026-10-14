// Tests for the simulated allocator: normal use and each failure in the Allocator table.

const std = @import("std");
const testing = std.testing;
const world_effects = @import("world_effects.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const SimulatedAllocator = world_effects.SimulatedAllocator;

test "an allocator with no failure allocates, resizes, remaps and frees" {
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    // A fixed buffer resizes the last allocation in place, which the debug allocator does not.
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var simulated = SimulatedAllocator.init(fixed.allocator(), &injector);
    const allocator = simulated.allocator();

    var memory = try allocator.alloc(u8, 16);
    memory[0] = 7;
    try testing.expect(allocator.resize(memory, 8));
    memory = memory[0..8];
    const moved = allocator.remap(memory, 12);
    try testing.expect(moved != null);
    allocator.free(moved.?);
    try testing.expectEqual(@as(usize, 3), injector.recorded.items.len);
}

test "an allocation returns error.OutOfMemory when the allocation fails and the next one works" {
    const plan = [_]injector_mod.Injection{failAt(.allocator, 1, "allocation_fails")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var simulated = SimulatedAllocator.init(testing.allocator, &injector);
    const allocator = simulated.allocator();

    const first = try allocator.alloc(u8, 4);
    defer allocator.free(first);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 4));
    const third = try allocator.alloc(u8, 4);
    allocator.free(third);
}

test "a resize reports it cannot resize in place when the resize fails" {
    const plan = [_]injector_mod.Injection{failAt(.allocator, 1, "resize_fails")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var simulated = SimulatedAllocator.init(fixed.allocator(), &injector);
    const allocator = simulated.allocator();

    const memory = try allocator.alloc(u8, 16);
    try testing.expect(!allocator.resize(memory, 8));
    try testing.expect(allocator.resize(memory, 8));
}

test "a remap reports it cannot move when the remap fails" {
    const plan = [_]injector_mod.Injection{failAt(.allocator, 1, "remap_fails")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var simulated = SimulatedAllocator.init(testing.allocator, &injector);
    const allocator = simulated.allocator();

    const memory = try allocator.alloc(u8, 16);
    defer allocator.free(memory);
    try testing.expect(allocator.remap(memory, 32) == null);
}

test "after a failed allocation the allocator gives no more memory but frees earlier memory" {
    const plan = [_]injector_mod.Injection{failAt(.allocator, 1, "free_of_a_failed_allocation")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var simulated = SimulatedAllocator.init(fixed.allocator(), &injector);
    const allocator = simulated.allocator();

    const kept = try allocator.alloc(u8, 16);
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 4));
    // The failure was injected once, but the allocator stays in the failed state.
    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 4));
    try testing.expect(simulated.is_exhausted);
    // Growing fails and shrinking works while freeing returns the memory to the backing allocator,
    // which the fixed buffer shows by being empty again.
    try testing.expect(!allocator.resize(kept, 32));
    try testing.expect(allocator.remap(kept, 32) == null);
    try testing.expect(allocator.resize(kept, 8));
    const shrunk: []u8 = kept[0..8];
    allocator.free(shrunk);
    try testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "every later call still asks the injector after the allocator is exhausted" {
    const plan = [_]injector_mod.Injection{failAt(.allocator, 0, "free_of_a_failed_allocation")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var simulated = SimulatedAllocator.init(testing.allocator, &injector);
    const allocator = simulated.allocator();

    _ = allocator.alloc(u8, 4) catch {};
    _ = allocator.alloc(u8, 4) catch {};
    try testing.expectEqual(@as(usize, 2), injector.recorded.items.len);
}

test "an allocation offers the allocation failures and not the resize failures" {
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    var simulated = SimulatedAllocator.init(testing.allocator, &injector);
    const allocator = simulated.allocator();

    const memory = try allocator.alloc(u8, 4);
    defer allocator.free(memory);
    try testing.expectEqualSlices(u8, &.{ 0, 3 }, injector.recorded.items[0].kinds);
}

test "a standard library container works over the simulated allocator and fails cleanly" {
    const plan = [_]injector_mod.Injection{failAt(.allocator, 0, "allocation_fails")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var simulated = SimulatedAllocator.init(testing.allocator, &injector);
    const allocator = simulated.allocator();

    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(allocator);
    try testing.expectError(error.OutOfMemory, list.append(allocator, 1));
    try list.append(allocator, 1);
    try testing.expectEqual(@as(usize, 1), list.items.len);
}
