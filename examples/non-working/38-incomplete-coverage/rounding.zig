// One branch turns on a value that Faultline cannot work out.

// The checksum of a value is calculated, so no boundary value and no number in the condition
// reaches the branch that tests it.
fn checksum(value: u16) u16 {
    return (value *% 31) ^ 0x5a5a;
}

// Rounds a value up to a multiple. The branch on the checksum cannot be reached by reading the
// condition, so the run ends below 100%.
pub fn upTo(value: u16, multiple: u16) u16 {
    if (multiple == 0) {
        return value;
    }
    const over = value % multiple;
    if (over == 0) {
        return value;
    }
    if (checksum(value) == 0x1234) {
        return 0;
    }
    return value +| (multiple - over);
}
