// The test root and the entry point for the simulated effects that are not files or directories:
// the network, the clock, secure random numbers, running another program, environment variables,
// threads, cancellation, the allocator and the writer.
//
// `install` layers the entries of `std.Io` that this part owns over an existing `Io`. It copies the
// vtable it is given, replaces only the entries about the network, the clock, random numbers, other
// programs, threads and cancellation and returns an `Io` that uses the copy. It never replaces an
// entry about files or directories, so it can be applied before or after the filesystem's own
// install and the two compose. The allocator, the writer and the environment are not in `Io`: they
// are types in their own files that take the injector directly.

const std = @import("std");
const injector_mod = @import("injector.zig");
const state = @import("effect_state.zig");
const network = @import("effect_network.zig");
const clock = @import("effect_clock.zig");
const random = @import("effect_random.zig");
const spawn = @import("effect_spawn.zig");
const thread = @import("effect_thread.zig");
const cancel = @import("effect_cancel.zig");

pub const SimulatedAllocator = @import("effect_allocator.zig").SimulatedAllocator;
pub const SimulatedWriter = @import("effect_writer.zig").SimulatedWriter;
pub const Environment = @import("effect_environment.zig").Environment;
pub const Injector = injector_mod.Injector;

// Runs a program in the simulated world: `std.process.run` without pipes, which can also report
// output past the limit and a time out.
pub const run = spawn.run;

// Starts a thread in the simulated world: `std.Thread.spawn` that can return the thread failures.
pub const spawnThread = thread.spawn;

// Starts the random generators from `value`, so a run and its replay see the same bytes.
pub const seedRandom = random.seed;

// Layers the simulated network, clock, random numbers, programs, threads and cancellation over
// `io`. The vtable is written into `room`, which has to outlive the returned `Io`, because an `Io`
// holds a pointer to its vtable. Every call that can fail asks `injector` once. Clears the state of
// every effect, so an install starts a clean world.
pub fn install(io: std.Io, room: *std.Io.VTable, injector: *Injector) std.Io {
    room.* = io.vtable.*;
    network.override(room);
    clock.override(room);
    random.override(room);
    spawn.override(room);
    thread.override(room);
    cancel.override(room);
    const layered: std.Io = .{ .userdata = io.userdata, .vtable = room };
    reset();
    state.attach(io, layered, injector);
    return layered;
}

// Clears the state of every effect: no socket is open, the clock is at its start, the random
// generators are at their default seed and no child is running. Does not detach the injector.
pub fn reset() void {
    network.reset();
    clock.reset();
    random.reset();
    spawn.reset();
    thread.reset();
}

test {
    _ = @import("effect_state.zig");
    _ = @import("effect_network.zig");
    _ = @import("effect_clock.zig");
    _ = @import("effect_random.zig");
    _ = @import("effect_spawn.zig");
    _ = @import("effect_thread.zig");
    _ = @import("effect_cancel.zig");
    _ = @import("effect_environment.zig");
    _ = @import("effect_allocator.zig");
    _ = @import("effect_writer.zig");
    _ = @import("world_effects.test.zig");
}
