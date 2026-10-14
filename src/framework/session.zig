// The simulated world one call of the function under test runs in: the filesystem, the network and
// everything else reached through `std.Io`, the allocator and a writer, all asking one injector.
//
// A session is begun once per call, in the child process the call runs in. Beginning one resets
// every part of the world, so no call sees what an earlier call left behind.

const std = @import("std");
const injector_mod = @import("injector.zig");
const filesystem = @import("filesystem.zig");
const world_effects = @import("world_effects.zig");

// How much a simulated writer takes before it reports that it is full. The code under test writes
// reports and messages, and this is far more than any of them need, so a writer is full only when a
// failure is injected.
pub const writer_capacity_bytes = 1024 * 1024;

pub const Session = struct {
    // Decides where failures happen and remembers every place a call reached.
    injector: injector_mod.Injector,

    // Where the vtables of the layered `Io` are kept. An `Io` points at its vtable, so these stay
    // where they are while the session is in use.
    effects_room: std.Io.VTable = undefined,
    files_room: std.Io.VTable = undefined,

    // The `Io` the code under test uses: the real one with the simulated world layered over it.
    io: std.Io = undefined,

    // The allocator the code under test uses. Each call it receives asks the injector.
    failing_allocator: world_effects.SimulatedAllocator = undefined,

    // Where a writer handed to the code under test puts its bytes.
    writer_contents: []u8 = &.{},
    writer: world_effects.SimulatedWriter = undefined,

    // The generator handed to code that takes a `std.Random`. Started from the run's seed.
    prng: std.Random.Xoshiro256 = undefined,

    // Starts the world in place. `real_io` is what the layers sit on, `plan` is the failures to
    // inject and `seed` starts every generator. The plan has to outlive the session.
    pub fn begin(self: *Session, places_allocator: std.mem.Allocator, real_io: std.Io, plan: []const injector_mod.Injection, seed: u64) !void {
        self.injector = injector_mod.Injector.init(places_allocator, plan);
        errdefer self.injector.deinit();

        filesystem.reset();
        const with_effects = world_effects.install(real_io, &self.effects_room, &self.injector);
        self.io = filesystem.install(with_effects, &self.files_room, &self.injector);
        world_effects.seedRandom(seed);

        self.failing_allocator = world_effects.SimulatedAllocator.init(std.heap.page_allocator, &self.injector);
        self.writer_contents = try std.heap.page_allocator.alloc(u8, writer_capacity_bytes);
        self.writer = world_effects.SimulatedWriter.init(self.writer_contents, &self.injector);
        self.prng = std.Random.Xoshiro256.init(seed);
    }

    // Lets go of what `begin` took.
    pub fn end(self: *Session) void {
        std.heap.page_allocator.free(self.writer_contents);
        self.writer_contents = &.{};
        self.injector.deinit();
    }

    // The allocator the code under test uses.
    pub fn allocator(self: *Session) std.mem.Allocator {
        return self.failing_allocator.allocator();
    }

    // The random source the code under test uses.
    pub fn random(self: *Session) std.Random {
        return self.prng.random();
    }

    // The places the calls made so far in this session reached, in order.
    pub fn places(self: *const Session) []const injector_mod.Place {
        return self.injector.recorded.items;
    }
};

test {
    _ = @import("session.test.zig");
}
