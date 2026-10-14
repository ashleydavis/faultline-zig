// The errors `describe` words, one value factory each.

// A file that is not there.
pub fn missingFile() anyerror {
    return error.FileNotFound;
}

// A file that cannot be opened.
pub fn deniedAccess() anyerror {
    return error.AccessDenied;
}
