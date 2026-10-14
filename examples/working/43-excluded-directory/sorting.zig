// The code under test. It is the only file the run measures, because `build.zig` leaves `bench`
// out.

// Whether the numbers are in order.
pub fn inOrder(numbers: []const u8) bool {
    var index: usize = 1;
    while (index < numbers.len) : (index += 1) {
        if (numbers[index] < numbers[index - 1]) {
            return false;
        }
    }
    return true;
}
