// A build script that is not part of the library. It has a branch no call exercises, which would
// fail the run if `.include` did not leave this directory out.

// Picks the name of the file to generate.
pub fn outputName(release: bool) []const u8 {
    if (release) {
        return "release.txt";
    }
    return "debug.txt";
}
