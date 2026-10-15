// What a run prints when it is not finished: one line per thing somebody has to do, and one number
// saying how much of the code has been exercised.
//
// The rest of the report says what happened. This says what to do about it, which is what somebody
// reading a run that did not reach 100% needs: a file, a line and the one thing to write there.

const std = @import("std");
const Style = @import("style.zig").Style;
const output_mod = @import("output.zig");

// What kind of work one checklist line asks for. Grouped by kind when printed, so the list is
// worked from the top and not jumped about in.
pub const Kind = enum {
    // A function whose parameter type nothing can build, so it is never called at all.
    value_factory,

    // A code path that no value Faultline found exercises.
    scenario,

    // A generic function, which Faultline cannot call because nothing says what its type
    // parameters stand for.
    generic_function,
};

// One thing to do. A field that a kind does not use is left empty.
pub const Item = struct {
    kind: Kind,

    // Where the work is.
    file: []const u8 = "",
    line: u32 = 0,

    // The function the work is in.
    function: []const u8 = "",

    // The code path's name, such as `if:9:false`, for a scenario.
    name: []const u8 = "",

    // The type a value factory has to return, for a value factory.
    type_name: []const u8 = "",
};

// The order kinds are printed in: what stops a function being called at all comes first, because
// nothing below it can be worked until it is done.
const kind_order = [_]Kind{ .value_factory, .generic_function, .scenario };

// How many items a terminal gets. The rest are in the report file, which holds every one.
//
// Ten because the list is in the order the work is worth doing in, and a first run against a
// project with no sim files has a long list. Printing all of it buries the coverage number and the
// file that holds the rest. Ten is enough to start on and short enough to read.
pub const terminal_limit = 10;

// How a count reads at the head of the list. Written out up to twelve because "Three things to
// do" reads as a sentence and "3 things to do" reads as a log line. Past that the digits are easier
// to take in than the word.
pub fn countWord(count: usize) []const u8 {
    return switch (count) {
        1 => "One",
        2 => "Two",
        3 => "Three",
        4 => "Four",
        5 => "Five",
        6 => "Six",
        7 => "Seven",
        8 => "Eight",
        9 => "Nine",
        10 => "Ten",
        11 => "Eleven",
        12 => "Twelve",
        else => "",
    };
}

// What the part of a function a code path name refers to is called in a sentence: `if:9:false` is
// "the false side of the if". The name is `<kind>:<line>:<side>`, or `<function>:entered` for the
// start of a function. Writes into `buffer` and returns the text, or null for a name it does not
// know.
pub fn phraseFor(buffer: []u8, name: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, name, ":entered")) {
        return "the start of the function";
    }
    const first = std.mem.indexOfScalar(u8, name, ':') orelse return null;
    const rest = name[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const kind = name[0..first];
    const side = rest[second + 1 ..];

    if (std.mem.eql(u8, kind, "if")) {
        return std.fmt.bufPrint(buffer, "the {s} side of the if", .{side}) catch null;
    }
    if (std.mem.eql(u8, kind, "switch")) {
        return std.fmt.bufPrint(buffer, "the {s} arm of the switch", .{side}) catch null;
    }
    if (std.mem.eql(u8, kind, "loop")) {
        if (std.mem.eql(u8, side, "body")) {
            return "the body of the loop";
        }
        return "the else side of the loop";
    }
    if (std.mem.eql(u8, kind, "catch")) {
        return "the fallback side of the catch";
    }
    if (std.mem.eql(u8, kind, "orelse")) {
        return "the fallback side of the orelse";
    }
    return null;
}

// Prints the list, grouped by kind, under a heading saying how many items there are. A kind with
// more than one item shown says what to write once, over a short line per item, rather than
// repeating the same sentence on every line. The line that says how many were not printed does
// not name the report file: the end of the report names it.
pub fn print(items: []const Item, style: Style) void {
    if (items.len == 0) {
        return;
    }

    const word = countWord(items.len);
    if (word.len != 0) {
        output_mod.print("\n  {s}{s} thing{s} to do:{s}\n", .{
            style.bold(),
            word,
            if (items.len == 1) "" else "s",
            style.reset(),
        });
    } else {
        output_mod.print("\n  {s}{d} things to do:{s}\n", .{ style.bold(), items.len, style.reset() });
    }

    var printed: usize = 0;
    for (kind_order) |kind| {
        var of_kind: usize = 0;
        for (items) |item| {
            if (item.kind == kind) {
                of_kind += 1;
            }
        }
        const shown = @min(of_kind, terminal_limit - printed);
        if (shown == 0) {
            continue;
        }
        if (shown > 1) {
            output_mod.print("    {s}{s}{s}\n", .{ style.dim(), headingFor(kind), style.reset() });
        }
        var done: usize = 0;
        for (items) |item| {
            if (item.kind != kind or done == shown) {
                continue;
            }
            if (shown == 1) {
                printOne(item, style);
            } else {
                printShort(item, style);
            }
            done += 1;
        }
        printed += shown;
    }

    if (items.len > printed) {
        output_mod.print("    {s}and {d} more.{s}\n", .{ style.dim(), items.len - printed, style.reset() });
    }
}

// What to write for every item of a kind, said once over a list of them.
fn headingFor(kind: Kind) []const u8 {
    return switch (kind) {
        .value_factory => "Each of these types needs a value factory of its own, so the function that takes it can be called:",
        .generic_function => "Each of these generic functions needs a scenario of its own that calls it, because Faultline cannot work out what their type parameters stand for:",
        .scenario => "Each of these code paths needs a value factory that reaches it or, where no value factory can, a scenario of its own:",
    };
}

// One item under its kind's heading: only what tells it from the others.
fn printShort(item: Item, style: Style) void {
    switch (item.kind) {
        .value_factory => output_mod.print("      {s}{s}, for {s} at {s}:{d}{s}\n", .{ style.dim(), item.type_name, item.function, item.file, item.line, style.reset() }),
        .generic_function => output_mod.print("      {s}{s} at {s}:{d}{s}\n", .{ style.dim(), item.function, item.file, item.line, style.reset() }),
        .scenario => {
            var buffer: [128]u8 = undefined;
            const phrase = phraseFor(&buffer, item.name) orelse "this code path";
            output_mod.print("      {s}{s} at {s}:{d} in {s}{s}\n", .{ style.dim(), phrase, item.file, item.line, item.function, style.reset() });
        },
    }
}

// One line of the list. Every one is a sentence that says what to write and where, so it can be
// acted on without the rest of the report being read.
fn printOne(item: Item, style: Style) void {
    // Far longer than any sentence, whose parts are a type name, a function name and a path.
    var buffer: [2048]u8 = undefined;
    var sentence = std.Io.Writer.fixed(&buffer);
    writeSentence(&sentence, item) catch {};
    output_mod.print("    {s}{s}{s}\n", .{ style.dim(), sentence.buffered(), style.reset() });
}

// Writes every item to `writer`, one line each in the order the terminal lists them, each line
// starting with `to do`, so the report file holds the items the terminal leaves out.
pub fn writeAll(writer: *std.Io.Writer, items: []const Item) std.Io.Writer.Error!void {
    for (kind_order) |kind| {
        for (items) |item| {
            if (item.kind != kind) {
                continue;
            }
            try writer.writeAll("to do ");
            try writeSentence(writer, item);
            try writer.writeByte('\n');
        }
    }
}

// Writes the sentence that says what to do about `item`.
fn writeSentence(writer: *std.Io.Writer, item: Item) std.Io.Writer.Error!void {
    switch (item.kind) {
        .value_factory => try writer.print(
            "Write a value factory returning {s}, which {s} takes. Without one, {s} at {s}:{d} cannot be called at all.",
            .{ item.type_name, item.function, item.function, item.file, item.line },
        ),
        .generic_function => try writer.print(
            "Write a scenario that calls {s} at {s}:{d}. It is generic, so Faultline cannot work out what its type parameters stand for.",
            .{ item.function, item.file, item.line },
        ),
        .scenario => {
            var buffer: [128]u8 = undefined;
            const phrase = phraseFor(&buffer, item.name) orelse "this code path";
            try writer.print("Write a value factory that reaches {s} at {s}:{d} in {s}, or a scenario that exercises it if no value factory can.", .{ phrase, item.file, item.line, item.function });
        },
    }
}

// The one number a run ends on: how many of the code paths it can observe were exercised.
pub fn printCoverage(ticked: usize, total: usize, style: Style) void {
    const percentage = percentageOf(ticked, total);
    const colour = if (percentage == 100) style.green() else style.red();
    output_mod.print(
        "\n  {s}{s}Coverage: {d} of {d} code paths, {d}%.{s}\n\n",
        .{ colour, style.bold(), ticked, total, percentage, style.reset() },
    );
}

// What fraction of the code paths were exercised, rounded down so a run one code path short of
// everything never reads as 100%. A run with nothing to fault test is 100%: there is no code path
// it failed to exercise.
pub fn percentageOf(ticked: usize, total: usize) usize {
    if (total == 0) {
        return 100;
    }
    return ticked * 100 / total;
}

test {
    _ = @import("checklist.test.zig");
}
