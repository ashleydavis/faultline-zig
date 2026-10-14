// A code path that no value reaches.

const std = @import("std");

// The two halves of the phrase this module compares against. The phrase is put together at compile
// time, so no literal in this file equals it and Faultline reads no value from the condition that
// matches it.
const opener = "open";
const ending = "-sesame";
const phrase = opener ++ ending;

// Whether the caller said the phrase. Nothing Faultline can pick or read reaches the true side, so
// the report asks for a scenario.
pub fn opens(said: []const u8) bool {
    if (std.mem.eql(u8, said, phrase)) {
        return true;
    } else {
        return false;
    }
}
