// Which functions, files and scenarios a run is about, when it was pointed at one file or one
// function with `-Dfile` or `-Dfunction`.

const std = @import("std");

// What a run was narrowed to. A null field means no narrowing on that.
pub const Selection = struct {
    // Only this file, relative to the project root.
    file: ?[]const u8 = null,

    // Only functions of this name. A method matches by its own name or as `Owner.name`.
    function: ?[]const u8 = null,

    // Whether anything was narrowed.
    pub fn isNarrowed(self: Selection) bool {
        return self.file != null or self.function != null;
    }

    // Whether a function in `file` called `name` is selected.
    pub fn includesFunction(self: Selection, file: []const u8, name: []const u8) bool {
        if (self.file) |only_file| {
            if (!isSamePath(only_file, file)) {
                return false;
            }
        }
        if (self.function) |only_function| {
            if (!std.mem.eql(u8, only_function, name) and !std.mem.eql(u8, only_function, bareName(name))) {
                return false;
            }
        }
        return true;
    }

    // Whether a source file is selected, for the code paths of the functions in it.
    pub fn includesFile(self: Selection, file: []const u8) bool {
        if (self.file) |only_file| {
            return isSamePath(only_file, file);
        }
        return true;
    }

    // Whether a scenario in the sim file `sim_path` is run. A scenario is about no function in
    // particular, so naming a function leaves scenarios out, and naming a file keeps the ones in
    // the sim file beside it.
    pub fn includesScenario(self: Selection, sim_path: []const u8) bool {
        if (self.function != null) {
            return false;
        }
        if (self.file) |only_file| {
            return std.mem.eql(u8, stemOf(trimDot(only_file)), stemOf(sim_path));
        }
        return true;
    }
};

// The name of a function without the struct it is a method of: `bump` for `Counter.bump`.
pub fn bareName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        return name[dot + 1 ..];
    }
    return name;
}

// Whether two paths name the same file, ignoring a leading `./`.
fn isSamePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, trimDot(a), trimDot(b));
}

fn trimDot(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./")) {
        return path[2..];
    }
    return path;
}

// A path without its `.zig` extension, or without `.sim.zig` for a sim file. A source file and the
// sim file beside it have the same stem.
pub fn stemOf(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".sim.zig")) {
        return path[0 .. path.len - ".sim.zig".len];
    }
    if (std.mem.endsWith(u8, path, ".zig")) {
        return path[0 .. path.len - ".zig".len];
    }
    return path;
}

test {
    _ = @import("selection.test.zig");
}
