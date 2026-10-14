// Ordinary code. This example is about the missing kcov and not about the code.

// The count itself, with nothing for an empty one.
pub fn classify(count: usize) usize {
    if (count == 0) {
        return 0;
    } else {
        return count;
    }
}
