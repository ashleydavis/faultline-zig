// Rounding for the project, kept in a directory with an ordinary name that nothing declares.

// Rounds up to the next multiple.
pub fn upTo(value: u16, multiple: u16) u16 {
    if (multiple == 0) {
        return value;
    }
    const over = value % multiple;
    if (over == 0) {
        return value;
    }
    return value +| (multiple - over);
}
