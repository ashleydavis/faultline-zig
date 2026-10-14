// Tests for how the simulated filesystem asks the injector and turns the answer into an error.

const std = @import("std");
const point = @import("point.zig");
const failures = @import("failures.zig");
const injector_mod = @import("injector.zig");
const faults = @import("filesystem_faults.zig");

const testing = std.testing;

// An error set with some of the errors a file open can return, for the tests below.
const OpenSet = error{ FileNotFound, AccessDenied, IsDir };

// An error set like a read's: it has no input or output error and no end of stream.
const NarrowSet = error{ Unexpected, AccessDenied };

// Makes `plan` the injector the module asks and puts it back to none when the test ends.
fn useInjector(inj: *injector_mod.Injector) void {
    faults.injector = inj;
}

test "indexOf finds the row with an id in the table of an effect" {
    try testing.expectEqual(@as(u8, 0), faults.indexOf(.read, "input_or_output_error"));
    try testing.expectEqual(@as(u8, 1), faults.indexOf(.read, "short_read"));
    try testing.expectEqual(@as(u8, 3), faults.indexOf(.read, "read_of_a_directory"));
    try testing.expectEqual(@as(u8, 0), faults.indexOf(.file_open, "file_not_found"));
}

test "isKind compares an index the injector picked with a row" {
    try testing.expect(faults.isKind(.read, "short_read", 1));
    try testing.expect(!faults.isKind(.read, "short_read", 0));
}

test "hasError says whether an error set has an error" {
    try testing.expect(faults.hasError(OpenSet, "IsDir"));
    try testing.expect(!faults.hasError(OpenSet, "NotDir"));

    // Every error is in `anyerror`.
    try testing.expect(faults.hasError(anyerror, "Anything"));
}

test "ask with no injector goes ahead and records nothing" {
    faults.injector = null;
    try testing.expectEqual(@as(?u8, null), faults.ask(.file_open, OpenSet, &.{"file_not_found"}));
}

test "ask records one place holding the rows the error set can express" {
    var inj = injector_mod.Injector.init(testing.allocator, &.{});
    defer inj.deinit();
    useInjector(&inj);
    defer faults.injector = null;

    // `not_a_directory` has no error in the set, so it is not offered. `short_read` is not an error,
    // so it is always offered.
    try testing.expectEqual(@as(?u8, null), faults.ask(.file_open, OpenSet, &.{ "file_not_found", "not_a_directory", "is_a_directory" }));
    try testing.expectEqual(@as(usize, 1), inj.recorded.items.len);
    try testing.expectEqualSlices(u8, &.{ 0, 2 }, inj.recorded.items[0].kinds);
    try testing.expectEqual(@as(?u8, null), faults.ask(.read, OpenSet, &.{ "short_read", "input_or_output_error" }));
    try testing.expectEqualSlices(u8, &.{1}, inj.recorded.items[1].kinds);
}

test "ask does not ask when no row can happen to the call" {
    var inj = injector_mod.Injector.init(testing.allocator, &.{});
    defer inj.deinit();
    useInjector(&inj);
    defer faults.injector = null;

    try testing.expectEqual(@as(?u8, null), faults.ask(.file_open, OpenSet, &.{"not_a_directory"}));
    try testing.expectEqual(@as(usize, 0), inj.recorded.items.len);
}

test "ask returns the index of the failure the plan names" {
    const plan = [_]injector_mod.Injection{.{ .point = .{ .effect = .file_open, .occurrence = 1 }, .kind = faults.indexOf(.file_open, "access_denied") }};
    var inj = injector_mod.Injector.init(testing.allocator, &plan);
    defer inj.deinit();
    useInjector(&inj);
    defer faults.injector = null;

    try testing.expectEqual(@as(?u8, null), faults.ask(.file_open, OpenSet, &.{ "file_not_found", "access_denied" }));
    try testing.expectEqual(@as(?u8, 1), faults.ask(.file_open, OpenSet, &.{ "file_not_found", "access_denied" }));
}

test "errorOf turns the picked row into the error its text names" {
    try testing.expectEqual(error.FileNotFound, faults.errorOf(.file_open, OpenSet, faults.indexOf(.file_open, "file_not_found")));
    try testing.expectEqual(error.IsDir, faults.errorOf(.file_open, OpenSet, faults.indexOf(.file_open, "is_a_directory")));
}

test "errorOf reports an input error as Unexpected when the set has no word for it" {
    try testing.expectEqual(error.Unexpected, faults.errorOf(.read, NarrowSet, faults.indexOf(.read, "input_or_output_error")));
    const WithIt = error{ InputOutput, Unexpected };
    try testing.expectEqual(error.InputOutput, faults.errorOf(.read, WithIt, faults.indexOf(.read, "input_or_output_error")));
}

test "errorOf reports a closed output as a broken pipe when that is the set's word" {
    const WriteSet = error{ BrokenPipe, InputOutput };
    try testing.expectEqual(error.BrokenPipe, faults.errorOf(.standard_stream, WriteSet, faults.indexOf(.standard_stream, "output_closed")));
}

test "errorOf reports a read-only filesystem as access denied when the set has no word for it" {
    const WriteSet = error{ AccessDenied, NoSpaceLeft };
    try testing.expectEqual(error.AccessDenied, faults.errorOf(.write, WriteSet, faults.indexOf(.write, "read_only_filesystem")));
    const WithIt = error{ AccessDenied, ReadOnlyFileSystem };
    try testing.expectEqual(error.ReadOnlyFileSystem, faults.errorOf(.write, WithIt, faults.indexOf(.write, "read_only_filesystem")));
}

test "failWith returns the error of the failure the plan names and null otherwise" {
    const plan = [_]injector_mod.Injection{.{ .point = .{ .effect = .file_open, .occurrence = 0 }, .kind = faults.indexOf(.file_open, "file_not_found") }};
    var inj = injector_mod.Injector.init(testing.allocator, &plan);
    defer inj.deinit();
    useInjector(&inj);
    defer faults.injector = null;

    try testing.expectEqual(@as(?OpenSet, error.FileNotFound), faults.failWith(.file_open, OpenSet, &.{ "file_not_found", "access_denied" }));
    try testing.expectEqual(@as(?OpenSet, null), faults.failWith(.file_open, OpenSet, &.{ "file_not_found", "access_denied" }));
}

test "every error row in the table names an error the table's text spells" {
    // Each row whose text starts with "error." must have a name made of letters and digits, which
    // is what `errorOf` reads out of it.
    inline for (comptime std.enums.values(point.Effect)) |effect| {
        for (failures.kindsOf(effect)) |kind| {
            if (std.mem.startsWith(u8, kind.returns, "error.")) {
                try testing.expect(std.ascii.isAlphabetic(kind.returns["error.".len]));
            }
        }
    }
}
