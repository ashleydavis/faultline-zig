// One of the project's two packages. Nothing in it imports the other.

// Whether no letter is lower case.
pub fn isShouted(text: []const u8) bool {
    for (text) |letter| {
        if (letter >= 'a' and letter <= 'z') {
            return false;
        }
    }
    return true;
}
