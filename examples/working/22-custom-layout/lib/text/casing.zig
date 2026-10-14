// Character tests for the text library.

// Whether the character is a lower case letter.
pub fn isLowerCase(character: u8) bool {
    if (character < 'a') {
        return false;
    }
    if (character > 'z') {
        return false;
    }
    return true;
}
