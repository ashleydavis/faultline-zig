const std = @import("std");
const checklist = @import("checklist.zig");
const output_mod = @import("output.zig");

fn printed(allocator: std.mem.Allocator, items: []const checklist.Item, report_path: []const u8) ![]u8 {
    var captured: std.Io.Writer.Allocating = .init(allocator);
    defer captured.deinit();

    output_mod.writer = &captured.writer;
    defer output_mod.writer = null;

    checklist.print(items, .init(false), report_path);
    return allocator.dupe(u8, captured.written());
}

test "countWord writes the count out up to twelve and stops there" {
    try std.testing.expectEqualStrings("One", checklist.countWord(1));
    try std.testing.expectEqualStrings("Twelve", checklist.countWord(12));
    try std.testing.expectEqualStrings("", checklist.countWord(13));
    try std.testing.expectEqualStrings("", checklist.countWord(0));
}

test "percentageOf rounds down and reads an empty run as complete" {
    try std.testing.expectEqual(@as(usize, 66), checklist.percentageOf(2, 3));
    try std.testing.expectEqual(@as(usize, 99), checklist.percentageOf(99, 100));
    try std.testing.expectEqual(@as(usize, 100), checklist.percentageOf(3, 3));
    try std.testing.expectEqual(@as(usize, 100), checklist.percentageOf(0, 0));
}

test "phraseFor names each kind of code path in words" {
    var buffer: [128]u8 = undefined;

    try std.testing.expectEqualStrings("the false side of the if", checklist.phraseFor(&buffer, "if:9:false").?);
    try std.testing.expectEqualStrings("the .large arm of the switch", checklist.phraseFor(&buffer, "switch:41:.large").?);
    try std.testing.expectEqualStrings("the body of the loop", checklist.phraseFor(&buffer, "loop:52:body").?);
    try std.testing.expectEqualStrings("the else side of the loop", checklist.phraseFor(&buffer, "loop:52:completed").?);
    try std.testing.expectEqualStrings("the fallback side of the catch", checklist.phraseFor(&buffer, "catch:7:taken").?);
    try std.testing.expectEqualStrings("the fallback side of the orelse", checklist.phraseFor(&buffer, "orelse:7:taken").?);
    try std.testing.expectEqualStrings("the start of the function", checklist.phraseFor(&buffer, "valueFor:entered").?);
    try std.testing.expect(checklist.phraseFor(&buffer, "nonsense") == null);
}

test "an empty list prints nothing" {
    const text = try printed(std.testing.allocator, &.{}, "full.txt");
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("", text);
}

test "a scenario item says what to write and where" {
    const items = [_]checklist.Item{.{ .kind = .scenario, .name = "if:9:false", .file = "sizing.zig", .line = 9, .function = "isLarge" }};
    const text = try printed(std.testing.allocator, &items, "full.txt");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "One thing to do:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Write a scenario exercising the false side of the if at sizing.zig:9 in isLarge.") != null);
}

test "a value factory item names the type and the function that takes it" {
    const items = [_]checklist.Item{.{ .kind = .value_factory, .type_name = "store.Store", .file = "store.zig", .line = 15, .function = "valueFor" }};
    const text = try printed(std.testing.allocator, &items, "full.txt");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Write a value factory returning store.Store, which valueFor takes. Without one, valueFor at store.zig:15 cannot be called at all.") != null);
}

test "value factory items are printed before scenario items" {
    const items = [_]checklist.Item{
        .{ .kind = .scenario, .name = "if:9:false", .file = "a.zig", .line = 9, .function = "first" },
        .{ .kind = .value_factory, .type_name = "T", .file = "b.zig", .line = 3, .function = "second" },
    };
    const text = try printed(std.testing.allocator, &items, "full.txt");
    defer std.testing.allocator.free(text);

    const factory_at = std.mem.indexOf(u8, text, "value factory").?;
    const scenario_at = std.mem.indexOf(u8, text, "scenario").?;
    try std.testing.expect(factory_at < scenario_at);
}

test "a list longer than the terminal limit says how many are in the report file" {
    var items: [checklist.terminal_limit + 3]checklist.Item = undefined;
    for (&items) |*item| {
        item.* = .{ .kind = .scenario, .name = "if:9:true", .file = "a.zig", .line = 9, .function = "f" };
    }
    const text = try printed(std.testing.allocator, &items, "full.txt");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "and 3 more, all of them in full.txt.") != null);
}

test "the coverage line gives the counts and the percentage" {
    var captured: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer captured.deinit();
    output_mod.writer = &captured.writer;
    defer output_mod.writer = null;

    checklist.printCoverage(2, 3, .init(false));

    try std.testing.expect(std.mem.indexOf(u8, captured.written(), "Coverage: 2 of 3 code paths, 66%.") != null);
}

test "a generic function item asks for a scenario that calls it" {
    const items = [_]checklist.Item{.{ .kind = .generic_function, .file = "lists.zig", .line = 4, .function = "first" }};
    const text = try printed(std.testing.allocator, &items, "full.txt");
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Write a scenario that calls first at lists.zig:4. It is generic, so Faultline cannot work out what its type parameters stand for.") != null);
}

test "writeAll writes every item, past the terminal limit, one line each in the order they are printed" {
    var items: [checklist.terminal_limit + 2]checklist.Item = undefined;
    for (&items, 0..) |*item, index| {
        item.* = .{ .kind = .scenario, .name = "if:9:false", .file = "a.zig", .line = @intCast(index + 1), .function = "run" };
    }
    items[items.len - 1] = .{ .kind = .value_factory, .type_name = "T", .file = "b.zig", .line = 3, .function = "second" };
    var written: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer written.deinit();

    try checklist.writeAll(&written.writer, &items);

    try std.testing.expectEqual(items.len, std.mem.count(u8, written.written(), "\n"));
    try std.testing.expect(std.mem.startsWith(u8, written.written(), "to do Write a value factory returning T, which second takes."));
    try std.testing.expect(std.mem.indexOf(u8, written.written(), "to do Write a scenario exercising the false side of the if at a.zig:11 in run.\n") != null);
}
