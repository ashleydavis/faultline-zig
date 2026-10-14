// The fixed list of boundary values for each built-in type and the values drawn from the run's
// random number generator. Boundary values are the ones that make a branch go one way rather than
// the other: zero, one and minus one because a loop or a sign check splits on them, the type's
// minimum and maximum because a range check has a side each. The generator's seed comes from the
// run and is carried in the replay token, so the same seed always gives the same values.

const std = @import("std");

// How many values the random number generator supplies for each type, besides the boundary values.
// A few, because the boundary values and the values read from the conditions in the source do the
// targeted work and these only add variety. Each one is another call per failure place, so more
// would cost more than they find.
pub const seeded_count: u32 = 4;

// The strings tried for a text parameter: the empty string and a one character string, which is
// where a parser's empty and shortest cases are decided.
pub const boundary_strings = [_][]const u8{ "", "a" };

// The length of a slice the callee is allowed to write into, besides empty and one element. Large
// enough that a function formatting a short number or a line into its buffer has room, which no
// empty or one element buffer gives it.
pub const roomy_length: usize = 64;

// The longest slice or string the generator builds. Short, because what matters is that the length
// differs between draws, not that the value is big.
pub const longest_seeded_length: usize = 8;

// The distinct boundary values of an integer type, in the order zero, one, minus one, minimum,
// maximum. A value the type cannot hold (one in a signed one bit integer, minus one in an unsigned
// type) is left out and so is a repeat (the maximum of a type with one value).
pub fn boundaryIntegers(comptime T: type) []const T {
    const list = comptime blk: {
        var found: [5]T = undefined;
        var length: usize = 0;
        const minimum = std.math.minInt(T);
        const maximum = std.math.maxInt(T);
        const wanted = [_]comptime_int{ 0, 1, -1, minimum, maximum };
        for (wanted) |value| {
            if (value < minimum or value > maximum) {
                continue;
            }
            var seen = false;
            for (found[0..length]) |earlier| {
                if (earlier == value) {
                    seen = true;
                }
            }
            if (!seen) {
                found[length] = value;
                length += 1;
            }
        }
        const out: [length]T = found[0..length].*;
        break :blk out;
    };
    return &list;
}

// The boundary values of a floating point type: zero, one, minus one and the most negative and
// most positive finite numbers. Infinity and not a number are left out because a value the type's
// own arithmetic would produce from a bug is the code under test's to meet, not an input.
pub fn boundaryFloats(comptime T: type) []const T {
    const list = comptime [_]T{ 0, 1, -1, -std.math.floatMax(T), std.math.floatMax(T) };
    return &list;
}

// Every tag of an enum, in declaration order.
pub fn boundaryTags(comptime T: type) []const T {
    return std.enums.values(T);
}

// Mixes the run's seed with the parameter's position and the choice's index into the seed of one
// value's generator. The position is in it so two parameters of the same type do not receive the
// same value, which would hide every branch that needs them to differ. The bytes are written
// little endian so the result is the same on every machine.
pub fn mixSeed(seed: u64, position: u32, index: u32) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], position, .little);
    std.mem.writeInt(u32, bytes[4..8], index, .little);
    return std.hash.Wyhash.hash(seed, &bytes);
}

// A random integer. Half the draws cover the type's whole range and half are small numbers, because
// the branches in real code compare against small constants far more often than against numbers
// near the extremes and the extremes are already in the boundary list.
pub fn seededInteger(comptime T: type, random: std.Random) T {
    if (random.boolean()) {
        return random.int(T);
    }
    const small = random.intRangeAtMost(i32, -256, 256);
    return std.math.cast(T, small) orelse std.math.cast(T, @abs(small)) orelse 0;
}

// A random floating point number between minus one thousand and one thousand. Wide enough to cross
// the thresholds code compares against, small enough to stay finite in any arithmetic.
pub fn seededFloat(comptime T: type, random: std.Random) T {
    const unit = random.float(f64) - 0.5;
    return @floatCast(unit * 2000.0);
}

// A random length for a slice, from none up to the longest the generator builds.
pub fn seededLength(random: std.Random) usize {
    return random.uintAtMost(usize, longest_seeded_length);
}

// A random string of lower case letters, with a random length. Allocated from the allocator given.
pub fn seededText(allocator: std.mem.Allocator, random: std.Random) error{OutOfMemory}![]u8 {
    const text = try allocator.alloc(u8, seededLength(random));
    for (text) |*letter| {
        letter.* = random.intRangeAtMost(u8, 'a', 'z');
    }
    return text;
}

test {
    _ = @import("boundary.test.zig");
}
