// The test root for the simulated filesystem: files, directories, symbolic links, the standard
// streams and the current directory. The effects reached other than through files are in
// `world_effects.zig`.

test {
    _ = @import("filesystem.zig");
}
