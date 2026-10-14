// Random numbers for the simulated world. Ordinary random bytes come from a generator started from a
// seed, so a run and its replay see the same bytes. Secure random bytes come from a second
// generator and can fail with "no entropy available".
//
// A function that asks for secure random bytes and gets `error.EntropyUnavailable` is what the
// table in `docs/FAILURES.md` asks for. The secure bytes are not secure here: nothing about them
// is unpredictable, which is the point.

const std = @import("std");
const state = @import("effect_state.zig");

// The seed used until `seed` is called, so a run that never asks for one is still repeatable.
pub const default_seed: u64 = 0x5eed_f417;

// The value mixed into the seed for the secure generator, so the two generators do not produce the
// same bytes. Any odd constant works, this one is the golden ratio in 64 bits.
const secure_mix: u64 = 0x9e37_79b9_7f4a_7c15;

// The generator behind ordinary random bytes.
var plain: std.Random.DefaultPrng = .init(default_seed);

// The generator behind secure random bytes.
var secure: std.Random.DefaultPrng = .init(default_seed ^ secure_mix);

const secure_kinds = state.kindsFor(.random, &.{"no_entropy_available"});

// Starts both generators from `value`. The run loop calls this with the seed in the replay token.
pub fn seed(value: u64) void {
    plain = .init(value);
    secure = .init(value ^ secure_mix);
}

// Starts both generators from the default seed.
pub fn reset() void {
    seed(default_seed);
}

// Writes the random entries of the `Io` vtable into `room`.
pub fn override(room: *std.Io.VTable) void {
    room.random = random;
    room.randomSecure = randomSecure;
}

fn random(_: ?*anyopaque, buffer: []u8) void {
    plain.random().bytes(buffer);
}

fn randomSecure(_: ?*anyopaque, buffer: []u8) std.Io.RandomSecureError!void {
    if (state.ask(.random, &secure_kinds) != null) {
        return error.EntropyUnavailable;
    }
    secure.random().bytes(buffer);
}

test {
    _ = @import("effect_random.test.zig");
}
