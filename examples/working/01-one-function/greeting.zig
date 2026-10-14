// The smallest thing Faultline can measure: one function with no branches.

// How long the name is. One code path, which is exercised by calling the function.
pub fn greet(name: []const u8) usize {
    return name.len;
}
