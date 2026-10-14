// A function taking `std.Random`. Faultline supplies a generator started from the seed of the run, so
// the same seed draws the same sequence.

const std = @import("std");

// Picks one of the words, or returns an empty string when there are none.
pub fn pick(random: std.Random, words: []const []const u8) []const u8 {
    if (words.len == 0) {
        return "";
    } else {
        return words[random.uintLessThan(usize, words.len)];
    }
}
