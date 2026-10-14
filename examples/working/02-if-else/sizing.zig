// An `if` with a written `else`, and a function whose branch depends on a number.

// Both sides of an `if` written out.
pub fn classify(count: usize) usize {
    if (count == 0) {
        return 0;
    } else {
        return count;
    }
}

// A condition against a number. The maximum of a `u32` is one of the boundary values Faultline
// calls with and it is above 1000, so it reaches the true side. Zero is another boundary value and
// it is below 1000, so it reaches the false side.
pub fn isLarge(value: u32) bool {
    if (value > 1000) {
        return true;
    }
    return false;
}
