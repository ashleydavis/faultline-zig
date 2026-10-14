// The file the run is narrowed to.

// How many of the values are above the floor.
pub fn countOver(values: []const u8, floor: u8) usize {
    var seen: usize = 0;
    for (values) |value| {
        if (value > floor) {
            seen += 1;
        }
    }
    return seen;
}
