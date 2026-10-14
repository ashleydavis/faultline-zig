// Shows where a crash happened, in the way Elm and Rust show an error: the file and line, the
// project's own code with a mark under the place, where it was called from, where the error came
// from, the failure Faultline injected and a hint for that kind of crash.
//
// What it works from is the stack trace a replay of the crashed call writes (`--replay <token>
// --trace`): the panic message, the error return context and the stack trace, each frame a line
// `<path>:<line>:<column>: 0x<address> in <function> (<module>)` followed by the source line and a
// caret. A frame is the project's when its path is under the copy of the project's sources or under
// the project itself. Every other frame is the standard library's or Faultline's.

const std = @import("std");
const style_mod = @import("style.zig");

// One frame of a trace.
pub const Frame = struct {
    // The path as the trace wrote it.
    path: []const u8,

    // The line, counting from one.
    line: u32,

    // The column, counting from one.
    column: u32,

    // The function, without the suffix the compiler adds to an instantiation.
    function: []const u8,
};

// What a traced replay wrote.
pub const Trace = struct {
    // The panic message, without the `panic: ` in front of it.
    message: []const u8 = "",

    // Where the error the code panicked on was returned, innermost first. Empty for a panic that
    // is not about an error.
    origin: []const Frame = &.{},

    // The stack when the code panicked, innermost first.
    stack: []const Frame = &.{},
};

// Reads what a traced replay wrote. Lines that are not frames, such as the source line and the
// caret under each frame, are passed over, and so are the colour codes Zig writes into a trace
// when the replay runs at a terminal or colour is forced. Everything is allocated from
// `allocator`.
pub fn parse(allocator: std.mem.Allocator, written: []const u8) !Trace {
    const text = try withoutColour(allocator, written);
    var trace: Trace = .{};
    var origin: std.ArrayList(Frame) = .empty;
    var stack: std.ArrayList(Frame) = .empty;
    var into = &stack;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "panic: ") and trace.message.len == 0) {
            trace.message = line["panic: ".len..];
        } else if (std.mem.eql(u8, line, "error return context:")) {
            into = &origin;
        } else if (std.mem.eql(u8, line, "stack trace:")) {
            into = &stack;
        } else if (frameOf(line)) |frame| {
            try into.append(allocator, frame);
        }
    }
    trace.origin = origin.items;
    trace.stack = stack.items;
    return trace;
}

// `text` with every terminal colour code taken out: an escape, `[`, any digits and semicolons, and
// the letter that ends the code.
pub fn withoutColour(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var plain: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
            var end = index + 2;
            while (end < text.len and (std.ascii.isDigit(text[end]) or text[end] == ';')) {
                end += 1;
            }
            index = if (end < text.len) end + 1 else end;
            continue;
        }
        try plain.append(allocator, text[index]);
        index += 1;
    }
    return plain.toOwnedSlice(allocator);
}

// The frame a trace line describes, or null for a line that is not one.
pub fn frameOf(line: []const u8) ?Frame {
    const address_at = std.mem.indexOf(u8, line, ": 0x") orelse return null;
    const place = line[0..address_at];
    const column_colon = std.mem.lastIndexOfScalar(u8, place, ':') orelse return null;
    const line_colon = std.mem.lastIndexOfScalar(u8, place[0..column_colon], ':') orelse return null;
    const line_number = std.fmt.parseInt(u32, place[line_colon + 1 .. column_colon], 10) catch return null;
    const column = std.fmt.parseInt(u32, place[column_colon + 1 ..], 10) catch return null;
    const rest = line[address_at..];
    const in_at = std.mem.indexOf(u8, rest, " in ") orelse return null;
    var function = rest[in_at + " in ".len ..];
    if (std.mem.lastIndexOf(u8, function, " (")) |module_at| {
        function = function[0..module_at];
    }
    if (std.mem.indexOf(u8, function, "__anon_")) |suffix_at| {
        function = function[0..suffix_at];
    }
    return .{
        .path = place[0..line_colon],
        .line = line_number,
        .column = column,
        .function = function,
    };
}

// The path of `path` relative to the project root when it is one of the project's files: under
// `sources_root`, the copy the run was built from, or under `repository`, the project itself. Null
// for a file of the standard library, of Faultline or of anything else.
pub fn projectPath(path: []const u8, sources_root: []const u8, repository: []const u8) ?[]const u8 {
    for ([_][]const u8{ sources_root, repository }) |root| {
        if (root.len == 0 or path.len <= root.len + 1) {
            continue;
        }
        if (std.mem.startsWith(u8, path, root) and path[root.len] == '/') {
            return path[root.len + 1 ..];
        }
    }
    return null;
}

// A short name for a file that is not the project's: `std/...` for the standard library, and the
// path as it is for anything else.
pub fn shortPath(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "/lib/std/")) |at| {
        return path[at + "/lib/".len ..];
    }
    return path;
}

// The injected failures a replay token names, as what Faultline made happen: `the 2nd delete call
// fail with "not a directory"` for `delete#1/not_a_directory`, joined with `and`. A token counts the
// calls of an effect from zero and the sentence from one. Null for a token that injects none.
pub fn injectedFailures(allocator: std.mem.Allocator, token: []const u8) !?[]const u8 {
    const fail_at = std.mem.indexOf(u8, token, ";fail=") orelse return null;
    var rest = token[fail_at + ";fail=".len ..];
    if (std.mem.indexOfScalar(u8, rest, ';')) |end| {
        rest = rest[0..end];
    }
    var text: std.Io.Writer.Allocating = .init(allocator);
    var parts = std.mem.splitScalar(u8, rest, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        const hash = std.mem.indexOfScalar(u8, part, '#') orelse continue;
        const slash = std.mem.indexOfScalar(u8, part, '/') orelse continue;
        if (slash < hash) {
            continue;
        }
        const occurrence = 1 + (std.fmt.parseInt(usize, part[hash + 1 .. slash], 10) catch continue);
        if (count != 0) {
            try text.writer.writeAll(" and ");
        }
        try text.writer.print("the {d}{s} {s} call fail with \"", .{ occurrence, ordinalSuffix(occurrence), part[0..hash] });
        for (part[slash + 1 ..]) |byte| {
            try text.writer.writeByte(if (byte == '_') ' ' else byte);
        }
        try text.writer.writeByte('"');
        count += 1;
    }
    if (count == 0) {
        return null;
    }
    return text.written();
}

// The letters after a number counted in words: `st` for 1, `nd` for 2, `rd` for 3 and `th` for
// the rest, `th` also for 11, 12 and 13.
pub fn ordinalSuffix(number: usize) []const u8 {
    if (number % 100 >= 11 and number % 100 <= 13) {
        return "th";
    }
    return switch (number % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

// What to do about a crash. `is_in_project` says whether the line that panicked is the project's
// own, and `is_injected_into_unreachable` whether it is a standard library `unreachable` reached
// through a failure Faultline injected. One or two sentences, written for whoever fixes the code.
pub fn hintFor(message: []const u8, is_in_project: bool, is_injected_into_unreachable: bool) []const u8 {
    if (is_injected_into_unreachable) {
        return "Likely a false alarm. Faultline made a call fail in a way the standard library says cannot happen at that point, so your code does not need to change for it.";
    }
    if (!is_in_project) {
        return "The panic is inside a function your code called. Check the values your code passes to it against what that function accepts.";
    }
    if (std.mem.startsWith(u8, message, "attempt to unwrap error")) {
        return "This line treats an error as one that cannot happen, with `catch unreachable` or an `unreachable` arm, but it happened. Return it with `try`, or catch it and handle it.";
    }
    if (std.mem.eql(u8, message, "attempt to use null value")) {
        return "This line uses an optional value that was null, with `.?` or `orelse unreachable`. Check for null with `if (value) |present|` or `orelse`, or make sure no caller can pass null.";
    }
    if (std.mem.startsWith(u8, message, "index out of bounds")) {
        return "This line reads past the end of a slice or array. Check the index against `len` before using it, or make sure no caller can pass an index that large.";
    }
    if (std.mem.startsWith(u8, message, "start index") or std.mem.startsWith(u8, message, "end index")) {
        return "This line slices with bounds outside the value or in the wrong order. Check both bounds against `len`, and the start against the end, before slicing.";
    }
    if (std.mem.eql(u8, message, "integer overflow")) {
        return "Arithmetic on this line went past what its type holds. Check the values before the arithmetic, or use `+%`, `-%` and `*%` where wrapping is meant or `+|`, `-|` and `*|` where saturating is meant.";
    }
    if (std.mem.eql(u8, message, "reached unreachable code")) {
        return "Code marked `unreachable` was reached, so what it assumes does not hold for these values. Handle the case, or make sure no caller can reach it.";
    }
    if (std.mem.eql(u8, message, "division by zero") or std.mem.startsWith(u8, message, "remainder division by zero")) {
        return "This line divides by zero. Check the divisor first.";
    }
    return "This line panics. Return an error instead, so the caller can say what went wrong, or make sure no caller can reach it.";
}

// What happened, in words, when Zig's own message names the wrong thing: an error that reached an
// `unreachable` arm reads in Zig as "attempt to unwrap error", which sounds like a `catch
// unreachable` in the caller. `line` is the source line that panicked. Null when Zig's message says
// it already.
pub fn plainMessage(allocator: std.mem.Allocator, message: []const u8, line: []const u8, function: []const u8) !?[]const u8 {
    if (std.mem.indexOf(u8, line, "unreachable") == null) {
        return null;
    }
    const unwrap = "attempt to unwrap error: ";
    if (std.mem.startsWith(u8, message, unwrap)) {
        return try std.fmt.allocPrint(allocator, "{s} reached an `unreachable` in {s}", .{ message[unwrap.len..], function });
    }
    if (std.mem.eql(u8, message, "reached unreachable code")) {
        return try std.fmt.allocPrint(allocator, "it reached an `unreachable` in {s}", .{function});
    }
    return null;
}

// Everything the view of one crash shows besides the trace.
pub const Crash = struct {
    // The function or scenario that was called.
    subject: []const u8,

    // The file it is in, relative to the project root.
    subject_file: []const u8 = "",

    // The replay token of the call.
    token: []const u8,

    // The values the call was made with, in words, such as the names of the value factories.
    inputs: []const u8 = "",

    // The command the crash started from, shown at the root of the stack trace: `zig build flt`
    // for a run, or the replay command for a replay.
    command: []const u8 = "zig build flt",

    // The copy of the project's sources the run was built from.
    sources_root: []const u8,

    // The project itself, whose files the code is shown from.
    repository: []const u8,

    // The colours, so the heading, the place, the mark and the hint stand out when scanned.
    style: style_mod.Style = .init(false),
};

// Writes the view of one crash to `writer`. Falls back to the panic message alone when the trace
// has no frame in the project.
pub fn write(writer: *std.Io.Writer, allocator: std.mem.Allocator, io: std.Io, trace: Trace, crash: Crash) !void {
    var project_at: ?usize = null;
    for (trace.stack, 0..) |frame, index| {
        if (projectPath(frame.path, crash.sources_root, crash.repository) != null) {
            project_at = index;
            break;
        }
    }

    const style = crash.style;
    const message = if (trace.message.len != 0) trace.message else "a crash";
    const subject = if (crash.subject_file.len != 0)
        try std.fmt.allocPrint(allocator, "{s} in {s}", .{ crash.subject, crash.subject_file })
    else
        crash.subject;
    const at = project_at orelse {
        try writer.print("{s}{s}{s} crashed: {s}{s}{s}\n", .{ style.bold(), subject, style.reset(), style.red(), message, style.reset() });
        return;
    };
    const frame = trace.stack[at];
    const file = projectPath(frame.path, crash.sources_root, crash.repository).?;
    const inner = trace.stack[0];
    const inner_source = if (at != 0) std.Io.Dir.cwd().readFileAlloc(io, inner.path, allocator, .unlimited) catch "" else "";
    const inner_line = lineOf(inner_source, inner.line);
    const injected = try injectedFailures(allocator, crash.token);
    const is_injected_into_unreachable = at != 0 and injected != null and std.mem.indexOf(u8, inner_line, "unreachable") != null;

    const heading = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ file, frame.line, frame.column });
    try writer.print("{s}{s}-- CRASH ", .{ style.red(), style.bold() });
    // Wide enough for the heading to end near the 100th column, as the rest of the output does.
    const rule_width: usize = 90;
    const used = "-- CRASH ".len + heading.len + 1;
    for (0..if (used < rule_width) rule_width - used else 3) |_| {
        try writer.writeByte('-');
    }
    try writer.print("{s} {s}{s}{s}{s}\n\n", .{ style.reset(), style.cyan(), style.bold(), heading, style.reset() });

    if (try plainMessage(allocator, message, inner_line, inner.function)) |plain| {
        try writer.print("{s}{s}{s} crashed: {s}{s}{s}.\n", .{ style.bold(), subject, style.reset(), style.red(), plain, style.reset() });
        try writer.print("{s}Zig's message: panic: {s}{s}\n", .{ style.dim(), message, style.reset() });
    } else {
        try writer.print("{s}{s}{s} crashed: {s}panic: {s}{s}\n", .{ style.bold(), subject, style.reset(), style.red(), message, style.reset() });
    }
    if (crash.inputs.len != 0) {
        try writer.print("It was called with {s}{s}{s}.\n", .{ style.bold(), crash.inputs, style.reset() });
    }
    const origin = originOf(trace.origin, crash);
    if (injected) |described| {
        if (origin) |source| {
            try writer.print("Faultline made {s}{s}{s}, in {s}{s}{s} at {s}{s}:{d}{s}.\n", .{
                style.yellow(),
                described,
                style.reset(),
                style.bold(),
                source.function,
                style.reset(),
                style.cyan(),
                locationOf(source, crash),
                source.line,
                style.reset(),
            });
        } else {
            try writer.print("Faultline made {s}{s}{s}.\n", .{ style.yellow(), described, style.reset() });
        }
    } else if (origin) |source| {
        try writer.print("The error came from {s}{s}{s} at {s}{s}:{d}{s}.\n", .{ style.bold(), source.function, style.reset(), style.cyan(), locationOf(source, crash), source.line, style.reset() });
    }

    if (at != 0) {
        try writer.print("\nIt panicked in {s}{s}{s} at {s}{s}:{d}{s}:\n\n", .{ style.bold(), inner.function, style.reset(), style.cyan(), shortPath(inner.path), inner.line, style.reset() });
        try writeLines(writer, style, inner_source, inner_source, inner);
        try writer.print("\nYour code called it at {s}{s}:{d}{s}:\n\n", .{ style.cyan(), file, frame.line, style.reset() });
    } else {
        try writer.writeByte('\n');
    }
    try writeCode(writer, allocator, io, crash, file, frame);

    try writeStack(writer, allocator, trace, crash, at);

    try writer.print("\n{s}{s}Hint:{s} {s}\n", .{ style.green(), style.bold(), style.reset(), hintFor(message, at == 0, is_injected_into_unreachable) });
}

// The stack trace in the order the calls were made: the command the crash started from at the
// root, then every frame from the outermost of the project's own down to the one that panicked,
// each with its function, file, line and column. Frames inside Faultline are left out, because the
// command stands for them.
fn writeStack(writer: *std.Io.Writer, allocator: std.mem.Allocator, trace: Trace, crash: Crash, project_at: usize) !void {
    const style = crash.style;
    var outermost = project_at;
    for (trace.stack, 0..) |frame, index| {
        if (projectPath(frame.path, crash.sources_root, crash.repository) != null) {
            outermost = index;
        }
    }

    var shown: std.ArrayList(Frame) = .empty;
    var index = outermost + 1;
    while (index > 0) {
        index -= 1;
        const frame = trace.stack[index];
        if (projectPath(frame.path, crash.sources_root, crash.repository) == null and !isStandardLibrary(frame.path)) {
            continue;
        }
        try shown.append(allocator, frame);
    }

    var widest: usize = 0;
    for (shown.items) |frame| {
        widest = @max(widest, frame.function.len);
    }

    try writer.print("\n{s}Stack trace, from the command to the panic:{s}\n", .{ style.bold(), style.reset() });
    try writer.print("    {s}{s}{s}\n", .{ style.dim(), crash.command, style.reset() });
    for (shown.items, 0..) |frame, position| {
        try writer.print("    {s}{s}{s}", .{ style.bold(), frame.function, style.reset() });
        for (0..widest - frame.function.len + 2) |_| {
            try writer.writeByte(' ');
        }
        try writer.print("{s}{s}:{d}:{d}{s}", .{ style.cyan(), locationOf(frame, crash), frame.line, frame.column, style.reset() });
        if (position + 1 == shown.items.len) {
            try writer.print("  {s}panicked here{s}", .{ style.red(), style.reset() });
        }
        try writer.writeByte('\n');
    }
}

// Whether a frame is in the standard library.
fn isStandardLibrary(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/lib/std/") != null;
}

// Where a frame is, as the view names it: relative to the project root for the project's files and
// from `std` for the standard library's.
fn locationOf(frame: Frame, crash: Crash) []const u8 {
    return projectPath(frame.path, crash.sources_root, crash.repository) orelse shortPath(frame.path);
}

// Where the error came from: the innermost frame of the error return context that is the project's
// or the standard library's. The frames inside Faultline's simulated world, where an injected
// failure is made, say nothing about the code.
pub fn originOf(origin: []const Frame, crash: Crash) ?Frame {
    for (origin) |frame| {
        if (projectPath(frame.path, crash.sources_root, crash.repository) != null or std.mem.indexOf(u8, frame.path, "/lib/std/") != null) {
            return frame;
        }
    }
    return null;
}

// Writes the line of `frame` with the two before it, from the project's own file, and a caret
// under the column. The column comes from the copy the run was built from, which has `pub ` in
// front of declarations the project keeps private, so it is moved back when the project's line is
// shorter by exactly that.
fn writeCode(writer: *std.Io.Writer, allocator: std.mem.Allocator, io: std.Io, crash: Crash, file: []const u8, frame: Frame) !void {
    const path = try std.fs.path.join(allocator, &.{ crash.repository, file });
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return;
    const copy_path = try std.fs.path.join(allocator, &.{ crash.sources_root, file });
    const copy = std.Io.Dir.cwd().readFileAlloc(io, copy_path, allocator, .unlimited) catch source;
    try writeLines(writer, crash.style, source, copy, frame);
}

// Writes line `frame.line` of `source` with the two before it and a caret under `frame.column`.
// `copy` is the text the column was counted in, which differs from `source` only by the `pub `
// the build puts in front of a private declaration. An empty `source` writes nothing.
fn writeLines(writer: *std.Io.Writer, style: style_mod.Style, source: []const u8, copy: []const u8, frame: Frame) !void {
    if (source.len == 0) {
        return;
    }

    const first = if (frame.line > 2) frame.line - 2 else 1;
    // Holds any line number.
    var number_buffer: [16]u8 = undefined;
    // The width of the largest line number shown, the line of the frame.
    const width = std.math.log10_int(frame.line) + 1;
    var number: u32 = 1;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |text| : (number += 1) {
        if (number < first) {
            continue;
        }
        if (number > frame.line) {
            break;
        }
        const label = std.fmt.bufPrint(&number_buffer, "{d}", .{number}) catch unreachable;
        for (0..width - label.len) |_| {
            try writer.writeByte(' ');
        }
        // The lines before the one that crashed are there to read it by, so they are dimmed.
        const shade = if (number == frame.line) style.bold() else style.dim();
        try writer.print("{s}{s} |{s} {s}{s}{s}\n", .{ style.dim(), label, style.reset(), shade, text, style.reset() });
        if (number == frame.line) {
            var column = frame.column;
            const copied = lineOf(copy, number);
            if (copied.len == text.len + "pub ".len and column > "pub ".len) {
                column -= "pub ".len;
            }
            for (0..width + " | ".len + column - 1) |_| {
                try writer.writeByte(' ');
            }
            try writer.print("{s}{s}^{s}\n", .{ style.red(), style.bold(), style.reset() });
        }
    }
}

// Line `number` of `text`, counting from one, or an empty slice past the end.
fn lineOf(text: []const u8, number: u32) []const u8 {
    var current: u32 = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (current += 1) {
        if (current == number) {
            return line;
        }
    }
    return "";
}

test {
    _ = @import("crash_view.test.zig");
}
