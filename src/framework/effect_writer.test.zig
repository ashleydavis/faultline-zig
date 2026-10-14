// Tests for the simulated writer: normal use and each failure in the Writer table.

const std = @import("std");
const testing = std.testing;
const world_effects = @import("world_effects.zig");
const effect_writer = @import("effect_writer.zig");
const injector_mod = @import("injector.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const SimulatedWriter = world_effects.SimulatedWriter;

test "a writer with no failure accepts writes until the buffer is full" {
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    var contents: [8]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try writer.interface.writeAll("abcd");
    try writer.interface.writeAll("efgh");
    try testing.expectEqualStrings("abcdefgh", writer.written());
    try testing.expectError(error.WriteFailed, writer.interface.writeAll("i"));
}

test "a writer takes a formatted print and every slice of a vectored write" {
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    var contents: [32]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try writer.interface.print("{d}-{s}", .{ 12, "x" });
    var parts = [_][]const u8{ "ab", "cd" };
    try writer.interface.writeVecAll(&parts);
    try testing.expectEqualStrings("12-xabcd", writer.written());
}

test "a repeated byte is written the number of times asked for" {
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    var contents: [16]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try writer.interface.splatByteAll('z', 5);
    try testing.expectEqualStrings("zzzzz", writer.written());
}

test "a write returns error.WriteFailed on the first write when the writer has no room" {
    const plan = [_]injector_mod.Injection{failAt(.writer, 0, "writer_has_no_room")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var contents: [8]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try testing.expectError(error.WriteFailed, writer.interface.writeAll("abc"));
    try testing.expectEqual(@as(usize, 0), writer.written().len);
    try writer.interface.writeAll("abc");
}

test "writes succeed until a fixed number of bytes and then return error.WriteFailed when the writer fills" {
    const plan = [_]injector_mod.Injection{failAt(.writer, 1, "writer_fills_part_way_through")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var contents: [64]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try writer.interface.writeAll("ab");
    try testing.expectError(error.WriteFailed, writer.interface.writeAll("cdefghij"));
    try testing.expectEqualStrings("abcdef", writer.written());
    try testing.expectEqual(@as(usize, 2 + effect_writer.fill_allowance), writer.written().len);
    try testing.expectError(error.WriteFailed, writer.interface.writeAll("k"));
}

test "a write accepts fewer bytes than offered on a short write" {
    const plan = [_]injector_mod.Injection{failAt(.writer, 0, "short_write")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var contents: [16]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    const accepted = try writer.interface.write("abcdefgh");
    try testing.expect(accepted > 0);
    try testing.expect(accepted < 8);
    try testing.expectEqualStrings("abcd", writer.written());
}

test "writeAll finishes after a short write because it loops" {
    const plan = [_]injector_mod.Injection{failAt(.writer, 0, "short_write")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var contents: [16]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try writer.interface.writeAll("abcdefgh");
    try testing.expectEqualStrings("abcdefgh", writer.written());
    try testing.expectEqual(@as(usize, 2), injector.recorded.items.len);
}

test "a one byte write cannot be short and is accepted whole" {
    const plan = [_]injector_mod.Injection{failAt(.writer, 0, "short_write")};
    var injector = injector_mod.Injector.init(testing.allocator, &plan);
    defer injector.deinit();
    var contents: [4]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try testing.expectEqual(@as(usize, 1), try writer.interface.write("a"));
}

test "every write asks the injector once with the three writer failures" {
    var injector = injector_mod.Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    var contents: [8]u8 = undefined;
    var writer = SimulatedWriter.init(&contents, &injector);

    try writer.interface.writeAll("a");
    try writer.interface.writeAll("b");
    try testing.expectEqual(@as(usize, 2), injector.recorded.items.len);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, injector.recorded.items[0].kinds);
}
