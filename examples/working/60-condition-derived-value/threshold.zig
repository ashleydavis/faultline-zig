// Functions whose branch is reached only by a number Faultline reads from a condition in this
// source.

// Whether the code unlocks the door. 48611 is not a boundary value of a `u32` and no calculation
// reaches it by chance, so the true side is reached by the number Faultline reads from the
// condition.
pub fn unlocks(code: u32) bool {
    if (code == 48_611) {
        return true;
    } else {
        return false;
    }
}

// The same for a smaller type, with no `else` and a body that returns.
pub fn isMagic(value: u16) bool {
    if (value == 31_337) {
        return true;
    }
    return false;
}
