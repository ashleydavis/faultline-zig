// A module the project registers in `build.zig` and other code reaches by name.

// Bytes as whole kilobytes, rounding down.
pub fn kilobytes(bytes: usize) usize {
    if (bytes < 1024) {
        return 0;
    }
    return bytes / 1024;
}
