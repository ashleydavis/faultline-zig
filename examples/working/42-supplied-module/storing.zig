// Code that reaches the project's `units` module by name. Nothing here says where that module's
// source is: `build.zig` registers it.

const units = @import("units");

// Whether a file of this size is worth storing whole, which it is once it rounds to a kilobyte.
pub fn storesWhole(bytes: usize) bool {
    if (units.kilobytes(bytes) == 0) {
        return false;
    }
    return true;
}
