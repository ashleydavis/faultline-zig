// An `if` with no `else`. What this shows is in the comments on each function.

// The body of this `if` does not leave the function, and there is no `else`. kcov has no line
// that proves the false side ran, so Faultline does not count that side and does not list it.
pub fn clampToHundred(value: u32) u32 {
    var result = value;
    if (value > 100) {
        result = 100;
    }
    return result;
}

// The body of this `if` returns, so the line after it runs only when the false side was taken.
// That line proves the false side, so Faultline counts both sides.
pub fn isLarge(value: u32) bool {
    if (value > 1000) {
        return true;
    }
    return false;
}
