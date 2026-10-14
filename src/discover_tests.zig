// The test root for discovery. It sits in `src/` and not in `src/cmd/` because the files there
// import the shared condition types from `src/framework/`, and Zig refuses an import that leaves
// the directory of the module's root file.

test {
    _ = @import("cmd/discover.zig");
    _ = @import("cmd/import_table.zig");
}
