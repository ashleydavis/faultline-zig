// What the tests of the simulated effects share: a world with a real `Io` underneath, the effects
// installed over it and an injector that fails the places a test names. Imported only by tests.

const std = @import("std");
const injector_mod = @import("injector.zig");
const state = @import("effect_state.zig");
const world_effects = @import("world_effects.zig");
const point = @import("point.zig");

// One failure at one place, named by the row's id in the effect's table, for a test's plan.
pub fn failAt(comptime effect: point.Effect, occurrence: u32, comptime id: []const u8) injector_mod.Injection {
    return .{ .point = .{ .effect = effect, .occurrence = occurrence }, .kind = state.kindIndex(effect, id) };
}

// A simulated world for one test. Start it in place with `start` and never move it, because the
// `Io` points into it.
pub const World = struct {
    // The real implementation the effects are layered over. Used for calls the effects leave alone.
    threaded: std.Io.Threaded,

    // The vtable with the effects in it.
    room: std.Io.VTable,

    // Asked by every effect.
    injector: injector_mod.Injector,

    // The `Io` the code under test is given.
    io: std.Io,

    // Starts a world that injects `plan`, which has to outlive the world.
    pub fn start(self: *World, plan: []const injector_mod.Injection) void {
        self.threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        self.injector = injector_mod.Injector.init(std.testing.allocator, plan);
        self.io = world_effects.install(self.threaded.io(), &self.room, &self.injector);
    }

    // Frees what the world holds and detaches the injector.
    pub fn stop(self: *World) void {
        state.injector = null;
        self.injector.deinit();
        self.threaded.deinit();
    }
};
