// Tests for `install`: that it layers only the entries this part owns, never an entry about files
// or directories and that two installs compose in either order.

const std = @import("std");
const testing = std.testing;
const world_effects = @import("world_effects.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

// An install that stands in for the filesystem's: it replaces file and directory entries only and
// copies the vtable it is given first, as the chain rule says.
fn installFileStub(io: std.Io, room: *std.Io.VTable) std.Io {
    room.* = io.vtable.*;
    room.dirOpenFile = stubOpenFile;
    room.fileLength = stubLength;
    room.operate = stubOperate;
    return .{ .userdata = io.userdata, .vtable = room };
}

fn stubOpenFile(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
    return error.FileNotFound;
}

fn stubLength(_: ?*anyopaque, _: std.Io.File) std.Io.File.LengthError!u64 {
    return 123;
}

fn stubOperate(_: ?*anyopaque, _: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    return error.Canceled;
}

// Whether a vtable entry is the same function in both vtables.
fn isSame(comptime field: []const u8, one: *const std.Io.VTable, other: *const std.Io.VTable) bool {
    return @field(one, field) == @field(other, field);
}

test "install leaves every file and directory entry as it was" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    defer @import("effect_state.zig").injector = null;

    @setEvalBranchQuota(100_000);
    var room: std.Io.VTable = undefined;
    const real = threaded.io();
    const layered = world_effects.install(real, &room, &injector);

    try testing.expectEqual(real.userdata, layered.userdata);
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |field| {
        const is_file_entry = comptime std.mem.startsWith(u8, field.name, "dir") or
            std.mem.startsWith(u8, field.name, "file") or
            std.mem.eql(u8, field.name, "operate") or
            std.mem.startsWith(u8, field.name, "batch") or
            std.mem.startsWith(u8, field.name, "process");
        if (is_file_entry and !comptime std.mem.startsWith(u8, field.name, "processSpawn")) {
            try testing.expect(isSame(field.name, real.vtable, &room));
        }
    }
}

test "install replaces the entries it owns" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    defer @import("effect_state.zig").injector = null;

    var room: std.Io.VTable = undefined;
    const real = threaded.io();
    _ = world_effects.install(real, &room, &injector);

    try testing.expect(!isSame("now", real.vtable, &room));
    try testing.expect(!isSame("sleep", real.vtable, &room));
    try testing.expect(!isSame("randomSecure", real.vtable, &room));
    try testing.expect(!isSame("netConnectIp", real.vtable, &room));
    try testing.expect(!isSame("processSpawn", real.vtable, &room));
    try testing.expect(!isSame("concurrent", real.vtable, &room));
    try testing.expect(!isSame("checkCancel", real.vtable, &room));
}

test "the file install applied after this one keeps this one's entries and its own" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    defer @import("effect_state.zig").injector = null;

    var effects_room: std.Io.VTable = undefined;
    var files_room: std.Io.VTable = undefined;
    const effects = world_effects.install(threaded.io(), &effects_room, &injector);
    const both = installFileStub(effects, &files_room);

    try testing.expectEqual(@as(u64, 123), try both.vtable.fileLength(both.userdata, undefined));
    try testing.expect(isSame("now", &effects_room, &files_room));
    try testing.expect(isSame("netConnectIp", &effects_room, &files_room));
    try testing.expectEqual(std.Io.Clock.real.now(both).nanoseconds, @import("effect_clock.zig").start_nanoseconds);
}

test "the file install applied before this one keeps its entries and this one's" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    defer @import("effect_state.zig").injector = null;

    var files_room: std.Io.VTable = undefined;
    var effects_room: std.Io.VTable = undefined;
    const files = installFileStub(threaded.io(), &files_room);
    const both = world_effects.install(files, &effects_room, &injector);

    try testing.expectEqual(@as(u64, 123), try both.vtable.fileLength(both.userdata, undefined));
    try testing.expect(isSame("dirOpenFile", &files_room, &effects_room));
    try testing.expect(isSame("operate", &files_room, &effects_room));
    try testing.expectEqual(std.Io.Clock.real.now(both).nanoseconds, @import("effect_clock.zig").start_nanoseconds);
}

test "both orders of install give the same vtable entries" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    defer @import("effect_state.zig").injector = null;

    var a_effects: std.Io.VTable = undefined;
    var a_files: std.Io.VTable = undefined;
    const a = installFileStub(world_effects.install(threaded.io(), &a_effects, &injector), &a_files);
    var b_files: std.Io.VTable = undefined;
    var b_effects: std.Io.VTable = undefined;
    const b = world_effects.install(installFileStub(threaded.io(), &b_files), &b_effects, &injector);

    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |field| {
        try testing.expect(@field(a.vtable, field.name) == @field(b.vtable, field.name));
    }
}

test "install clears the state left by an earlier world" {
    const plan = [_]injector_mod.Injection{};
    var world: World = undefined;
    world.start(&plan);
    try std.Io.sleep(world.io, .fromSeconds(30), .real);
    _ = try (std.Io.net.IpAddress{ .ip4 = .loopback(1) }).connect(world.io, .{ .mode = .stream });
    world.stop();

    world.start(&plan);
    defer world.stop();
    try testing.expectEqual(@import("effect_clock.zig").start_nanoseconds, std.Io.Clock.real.now(world.io).nanoseconds);
    try testing.expectEqual(@as(usize, 0), @import("effect_network.zig").countOpen());
}

test "a place is numbered per effect across the effects of one world" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    _ = std.Io.Clock.real.now(world.io);
    try world.io.checkCancel();
    _ = std.Io.Clock.real.now(world.io);
    const recorded = world.injector.recorded.items;
    try testing.expectEqual(@as(usize, 3), recorded.len);
    try testing.expectEqual(@as(u32, 1), recorded[2].point.occurrence);
    try testing.expectEqual(@as(u32, 0), recorded[1].point.occurrence);
}
