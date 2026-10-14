// Code a replay reproduces. The token carries the seed of the run as well as the values chosen, so
// the same token draws the same random number again.

const std = @import("std");

// Says whether the draw came out inside the bound.
pub fn withinBound(random: std.Random, bound: usize) bool {
    if (bound == 0) {
        return false;
    } else {
        return random.uintLessThan(usize, bound) < bound;
    }
}
