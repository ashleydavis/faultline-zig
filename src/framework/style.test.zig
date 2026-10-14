// Tests for the colour codes and marks a report is written with.

const std = @import("std");
const Style = @import("style.zig").Style;

test "with colour off every helper is empty, so the same prints produce plain text" {
    const style = Style.init(false);
    try std.testing.expectEqualStrings("", style.green());
    try std.testing.expectEqualStrings("", style.red());
    try std.testing.expectEqualStrings("", style.yellow());
    try std.testing.expectEqualStrings("", style.bold());
    try std.testing.expectEqualStrings("", style.dim());
    try std.testing.expectEqualStrings("", style.reset());
}

test "with colour off the marks are words, so a captured run reads without a terminal" {
    const style = Style.init(false);
    try std.testing.expectEqualStrings("ok  ", style.pass());
    try std.testing.expectEqualStrings("FAIL", style.fail());
    try std.testing.expectEqualStrings("MISS", style.miss());
    try std.testing.expectEqualStrings("skip", style.skip());
}

test "with colour on every helper is an escape sequence" {
    const style = Style.init(true);
    for ([_][]const u8{ style.green(), style.red(), style.yellow(), style.bold(), style.dim(), style.reset() }) |code| {
        try std.testing.expect(code.len != 0);
        try std.testing.expectEqual(@as(u8, 0x1b), code[0]);
    }
}

test "a missed function and a failed run are marked differently in words and the same in colour" {
    const plain = Style.init(false);
    // A miss is work found rather than the run having failed at that line, so the two read
    // differently where there is room to say so.
    try std.testing.expect(!std.mem.eql(u8, plain.miss(), plain.fail()));

    const coloured = Style.init(true);
    try std.testing.expectEqualStrings(coloured.fail(), coloured.miss());
}
