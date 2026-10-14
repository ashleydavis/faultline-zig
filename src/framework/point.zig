// Where in one call a simulated effect can fail.
//
// A place is named by what kind of effect it is and how many calls of that kind came before it in
// the same call of the function under test, so two runs that make the same calls in the same order
// agree on every place without either of them counting anything for the other. The code under test
// is reached through the simulated `std.Io`, the failing allocator and the simulated writer, none
// of which can tell what line of the project's code called them, so a place is never a source line.

const std = @import("std");

// The groups of effects a function can use. One per group in `docs/FAILURES.md`, in the same
// order, so the table and this list read the same way.
pub const Effect = enum {
    allocator,
    file_open,
    read,
    write,
    link,
    directory_listing,
    network,
    clock,
    writer,
    delete,
    make_directory,
    resolve_path,
    standard_stream,
    spawn,
    environment,
    thread,
    cancellation,
    rename_copy,
    attributes,
    file_state,
    random,
    current_directory,
};

// How many effects there are, for the per-effect call counters an injector keeps.
pub const effect_count = @typeInfo(Effect).@"enum".fields.len;

// One place a simulated effect can fail: the occurrence-th call of that effect in this call of the
// function under test, counting from zero.
pub const Point = struct {
    // What kind of effect the call was.
    effect: Effect,

    // How many calls of the same effect came before this one in the same call.
    occurrence: u32,

    // Whether two points name the same place.
    pub fn eql(self: Point, other: Point) bool {
        return self.effect == other.effect and self.occurrence == other.occurrence;
    }

    // Formats a point the way a replay token and a failure message both read it: "effect#occurrence".
    pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}#{d}", .{ @tagName(self.effect), self.occurrence });
    }
};

test {
    _ = @import("point.test.zig");
}
