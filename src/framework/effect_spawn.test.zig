// Tests for running another program: a program that runs and every failure in the table.

const std = @import("std");
const testing = std.testing;
const spawn = @import("effect_spawn.zig");
const world_effects = @import("world_effects.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

const argv = [_][]const u8{ "tool", "--flag" };

fn startChild(world: *World) !std.process.Child {
    return std.process.spawn(world.io, .{ .argv = &argv });
}

test "a spawn with no failure returns a child that exits with code 0" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var child = try startChild(&world);
    try testing.expect(child.id != null);
    const term = try child.wait(world.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
    try testing.expect(child.id == null);
}

test "two children get different identifiers" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var first = try startChild(&world);
    var second = try startChild(&world);
    try testing.expect(first.id.? != second.id.?);
    first.kill(world.io);
    second.kill(world.io);
    try testing.expect(first.id == null);
}

test "spawnPath behaves like spawn" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var child = try std.process.spawnPath(world.io, std.Io.Dir.cwd(), .{ .argv = &argv });
    const term = try child.wait(world.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
}

test "a spawn returns error.FileNotFound when the program is not found" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 0, "program_not_found")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.FileNotFound, startChild(&world));
}

test "a spawn returns error.AccessDenied when access is denied" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 0, "access_denied")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.AccessDenied, startChild(&world));
}

test "a spawn returns error.InvalidExe when the file is not an executable" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 0, "not_an_executable")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.InvalidExe, startChild(&world));
}

test "a spawn returns error.ProcessFdQuotaExceeded when there are too many open files" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 0, "too_many_open_files")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.ProcessFdQuotaExceeded, startChild(&world));
}

test "a spawn returns error.OutOfMemory when memory runs out" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 0, "out_of_memory")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.OutOfMemory, startChild(&world));
}

test "a wait returns .exited with a non-zero code when the program exits with a non-zero code" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 1, "exits_with_a_non_zero_code")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var child = try startChild(&world);
    const term = try child.wait(world.io);
    try testing.expect(term.exited != 0);
}

test "a wait returns .signal when the program is killed by a signal" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 1, "killed_by_a_signal")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var child = try startChild(&world);
    const term = try child.wait(world.io);
    try testing.expectEqual(std.posix.SIG.KILL, term.signal);
}

test "run with no failure returns code 0 and empty output the caller owns" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const result = try world_effects.run(testing.allocator, world.io, .{ .argv = &argv });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(@as(u8, 0), result.term.exited);
    try testing.expectEqual(@as(usize, 0), result.stdout.len);
    try testing.expectEqual(@as(usize, 0), result.stderr.len);
    try testing.expectEqual(@as(usize, 3), world.injector.recorded.items.len);
}

test "run returns error.FileNotFound when the program is not found" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 0, "program_not_found")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.FileNotFound, world_effects.run(testing.allocator, world.io, .{ .argv = &argv }));
}

test "run returns error.StreamTooLong when the output is past the limit" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 1, "output_past_the_limit")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.StreamTooLong, world_effects.run(testing.allocator, world.io, .{ .argv = &argv, .stdout_limit = .limited(10) }));
}

test "run returns error.Timeout when the program timed out" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 1, "timed_out")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.Timeout, world_effects.run(testing.allocator, world.io, .{ .argv = &argv }));
}

test "run with no limit offers only the time out failure for the output" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const result = try world_effects.run(testing.allocator, world.io, .{ .argv = &argv });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(@as(usize, 1), world.injector.recorded.items[1].kinds.len);

    world.injector.reset();
    const limited = try world_effects.run(testing.allocator, world.io, .{ .argv = &argv, .stderr_limit = .limited(5) });
    defer testing.allocator.free(limited.stdout);
    defer testing.allocator.free(limited.stderr);
    try testing.expectEqual(@as(usize, 2), world.injector.recorded.items[1].kinds.len);
}

test "run returns the failing wait of a program that exits with a non-zero code" {
    const plan = [_]injector_mod.Injection{failAt(.spawn, 2, "exits_with_a_non_zero_code")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const result = try world_effects.run(testing.allocator, world.io, .{ .argv = &argv });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expect(result.term.exited != 0);
}

test "reset starts the identifiers again" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var first = try startChild(&world);
    const id = first.id.?;
    first.kill(world.io);
    spawn.reset();
    var second = try startChild(&world);
    try testing.expectEqual(id, second.id.?);
    second.kill(world.io);
}
