// A file the run is not narrowed to. It needs scenarios that nobody has written, and the run
// reaching 100% for the other file shows that this one is not counted.

// A word for the number. The checks use a number Faultline cannot work out from the source alone.
pub fn describe(value: u8) []const u8 {
    if (checksum(value) == 0x1f) {
        return "special";
    }
    return "ordinary";
}

// Folds the number into one byte.
fn checksum(value: u8) u8 {
    return (value *% 31) ^ 0x55;
}
