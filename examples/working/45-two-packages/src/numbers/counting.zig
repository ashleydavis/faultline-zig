// The other package. Nothing in it imports the first.

// How many of the numbers are above the floor.
pub fn above(numbers: []const u8, floor: u8) usize {
    var counted: usize = 0;
    for (numbers) |number| {
        if (number > floor) {
            counted += 1;
        }
    }
    return counted;
}
