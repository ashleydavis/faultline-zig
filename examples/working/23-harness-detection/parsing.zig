// Ordinary code, which is what gets a report.

// How many characters of the text are digits.
pub fn digitsIn(text: []const u8) usize {
    var found: usize = 0;
    for (text) |character| {
        if (character >= '0' and character <= '9') {
            found += 1;
        }
    }
    return found;
}
