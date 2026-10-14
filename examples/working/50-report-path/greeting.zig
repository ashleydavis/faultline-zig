// The smallest thing Faultline can measure: one function with no branches.

// How long the name is.
pub fn greet(name: []const u8) usize {
    return name.len;
}
