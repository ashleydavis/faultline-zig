// What a child process says about one call, and how the parent reads it back.
//
// The report is plain text, one record per line, with the fields of a record separated by tabs, so
// a report can be read in a terminal when something goes wrong. A field has a tab, a newline or a
// backslash escaped, so any text an expectation carries survives the trip. A line the reader does
// not recognise is passed over on purpose: a report cut short by a crash is still read as far as
// it goes.

const std = @import("std");
const point = @import("point.zig");
const injector = @import("injector.zig");

// What a call came to, as far as the call itself says. A crash is not here: the parent learns of
// it from how the child ended, not from anything the child wrote.
pub const Result = union(enum) {
    // The function returned without an error.
    returned,

    // The function returned an error with this name.
    errored: []const u8,

    // An expectation was false.
    expectation_failed: ExpectationFailure,
};

// Where an expectation was false and what it said.
pub const ExpectationFailure = struct {
    // The expectation function or scenario it was written in. Empty when the call itself failed an
    // expectation, which a plain function cannot do.
    function: []const u8,

    // The file the expectation is in, as `@src()` reports it.
    file: []const u8,

    // The line the expectation is on.
    line: u32,

    // What the author wrote the expectation to say.
    text: []const u8,
};

// Everything the parent keeps from one call.
pub const Report = struct {
    // What the call came to. Null when the child did not say, which is what a crash looks like.
    result: ?Result = null,

    // Every place the call reached where something could fail, in the order reached.
    places: []injector.Place = &.{},

    // The memory behind the strings and slices above, released by `deinit`.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Report) void {
        if (self.arena) |*arena| {
            arena.deinit();
        }
        self.* = .{};
    }
};

// Writes a report as text.
pub fn write(writer: *std.Io.Writer, result: Result, places: []const injector.Place) std.Io.Writer.Error!void {
    switch (result) {
        .returned => try writer.writeAll("R\treturned\n"),
        .errored => |name| {
            try writer.writeAll("R\terrored\t");
            try writeField(writer, name);
            try writer.writeByte('\n');
        },
        .expectation_failed => |failure| {
            try writer.writeAll("R\texpectation\t");
            try writeField(writer, failure.function);
            try writer.writeByte('\t');
            try writeField(writer, failure.file);
            try writer.print("\t{d}\t", .{failure.line});
            try writeField(writer, failure.text);
            try writer.writeByte('\n');
        },
    }
    for (places) |place| {
        try writer.print("P\t{s}\t{d}\t", .{ @tagName(place.point.effect), place.point.occurrence });
        for (place.kinds, 0..) |kind, index| {
            if (index != 0) {
                try writer.writeByte(',');
            }
            try writer.print("{d}", .{kind});
        }
        try writer.writeByte('\n');
    }
}

// Reads a report back. What does not parse is left out and what does is kept.
pub fn read(allocator: std.mem.Allocator, bytes: []const u8) !Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const room = arena.allocator();

    var report: Report = .{};
    var places: std.ArrayList(injector.Place) = .empty;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        var fields = std.mem.splitScalar(u8, line, '\t');
        const tag = fields.next() orelse continue;
        if (std.mem.eql(u8, tag, "R")) {
            report.result = try readResult(room, &fields);
        } else if (std.mem.eql(u8, tag, "P")) {
            if (try readPlace(room, &fields)) |place| {
                try places.append(room, place);
            }
        }
    }

    report.places = try places.toOwnedSlice(room);
    report.arena = arena;
    return report;
}

fn readResult(room: std.mem.Allocator, fields: *std.mem.SplitIterator(u8, .scalar)) !?Result {
    const kind = fields.next() orelse return null;
    if (std.mem.eql(u8, kind, "returned")) {
        return .returned;
    }
    if (std.mem.eql(u8, kind, "errored")) {
        const name = fields.next() orelse return null;
        return .{ .errored = try unescape(room, name) };
    }
    if (std.mem.eql(u8, kind, "expectation")) {
        const function = fields.next() orelse return null;
        const file = fields.next() orelse return null;
        const line_text = fields.next() orelse return null;
        const text = fields.next() orelse return null;
        const line = std.fmt.parseInt(u32, line_text, 10) catch return null;
        return .{ .expectation_failed = .{
            .function = try unescape(room, function),
            .file = try unescape(room, file),
            .line = line,
            .text = try unescape(room, text),
        } };
    }
    return null;
}

fn readPlace(room: std.mem.Allocator, fields: *std.mem.SplitIterator(u8, .scalar)) !?injector.Place {
    const effect_text = fields.next() orelse return null;
    const occurrence_text = fields.next() orelse return null;
    const kinds_text = fields.next() orelse "";
    const effect = std.meta.stringToEnum(point.Effect, effect_text) orelse return null;
    const occurrence = std.fmt.parseInt(u32, occurrence_text, 10) catch return null;

    var kinds: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, kinds_text, ',');
    while (parts.next()) |part| {
        if (part.len == 0) {
            continue;
        }
        const kind = std.fmt.parseInt(u8, part, 10) catch return null;
        try kinds.append(room, kind);
    }
    return .{
        .point = .{ .effect = effect, .occurrence = occurrence },
        .kinds = try kinds.toOwnedSlice(room),
    };
}

// Writes a field with the characters that would break the record escaped.
pub fn writeField(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| {
        switch (byte) {
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            '\\' => try writer.writeAll("\\\\"),
            else => try writer.writeByte(byte),
        }
    }
}

// Undoes `writeField`.
pub fn unescape(room: std.mem.Allocator, text: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\\' and index + 1 < text.len) {
            index += 1;
            switch (text[index]) {
                't' => try plain.append(room, '\t'),
                'n' => try plain.append(room, '\n'),
                else => try plain.append(room, text[index]),
            }
            continue;
        }
        try plain.append(room, text[index]);
    }
    return plain.toOwnedSlice(room);
}

test {
    _ = @import("wire.test.zig");
}
