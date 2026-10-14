const std = @import("std");
const coverage = @import("coverage.zig");
const covered_lines = @import("covered_lines.zig");

// A small function to read: an `if` with an `else`, a three-way `switch` and a `while` loop, each
// body on a line of its own. `std.zig.Ast` only parses this. No identifier in it is resolved and
// nothing in it runs.
const fixture_source =
    \\fn sample(flag: bool, count: usize, choice: u8) void {
    \\    if (flag) {
    \\        doSomething();
    \\    } else {
    \\        doOther();
    \\    }
    \\
    \\    switch (choice) {
    \\        1 => {
    \\            caseOne();
    \\        },
    \\        2 => {
    \\            caseTwo();
    \\        },
    \\        else => {
    \\            caseElse();
    \\        },
    \\    }
    \\
    \\    var index: usize = 0;
    \\    while (index < count) : (index += 1) {
    \\        doWork();
    \\    }
    \\}
;

// The checklist's path named `name`, or null.
fn pathNamed(checklist: coverage.Checklist, name: []const u8) ?coverage.Path {
    for (checklist.paths) |path| {
        if (std.mem.eql(u8, path.name, name)) {
            return path;
        }
    }
    return null;
}

// Whether the path named `name` is ticked. A name that is not on the checklist is not ticked.
fn isTicked(checklist: coverage.Checklist, name: []const u8) bool {
    for (checklist.paths, 0..) |path, index| {
        if (std.mem.eql(u8, path.name, name)) {
            return checklist.ticked[index];
        }
    }
    return false;
}

// The witness line of the path named `name`, or an error naming the code path that is not there.
fn witnessOf(checklist: coverage.Checklist, name: []const u8) !u32 {
    const path = pathNamed(checklist, name) orelse {
        std.debug.print("no code path named \"{s}\"\n", .{name});
        return error.NoSuchPath;
    };
    return path.witness;
}

// A set of lines the way kcov reports them: every line in `code` has code and the ones in `hit`
// ran.
fn linesWith(allocator: std.mem.Allocator, code: []const u32, hit: []const u32) !coverage.LineSet {
    var set: coverage.LineSet = .{};
    errdefer set.deinit(allocator);
    for (code) |line| {
        try set.code.put(allocator, line, {});
    }
    for (hit) |line| {
        try set.hit.put(allocator, line, {});
    }
    return set;
}

test "build reads a function's branches from its own source" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", fixture_source, "sample");
    defer checklist.deinit();

    try std.testing.expectEqualStrings("sample", checklist.function);
    try std.testing.expectEqualStrings("fixture.zig", checklist.file);

    // An exact list of (line, name, witness), so a branch at the wrong line fails as surely as a
    // missing one. The function's own entry comes first.
    const Expected = struct { line: u32, name: []const u8, witness: u32 };
    const expected = [_]Expected{
        .{ .line = 1, .name = "sample:entered", .witness = 2 },
        .{ .line = 2, .name = "if:2:true", .witness = 3 },
        .{ .line = 4, .name = "if:4:false", .witness = 5 },
        .{ .line = 9, .name = "switch:9:1", .witness = 10 },
        .{ .line = 12, .name = "switch:12:2", .witness = 13 },
        .{ .line = 15, .name = "switch:15:else", .witness = 16 },
        .{ .line = 21, .name = "loop:21:body", .witness = 22 },
    };
    try std.testing.expectEqual(expected.len, checklist.paths.len);
    for (expected, checklist.paths) |want, got| {
        try std.testing.expectEqual(want.line, got.line);
        try std.testing.expectEqualStrings(want.name, got.name);
        try std.testing.expectEqual(want.witness, got.witness);
    }
    try std.testing.expectEqual(@as(usize, 0), checklist.unprovable);
}

test "a function with no branches has one code path, its own entry" {
    const allocator = std.testing.allocator;
    const source =
        \\fn plain(value: i64) i64 {
        \\    return value + 1;
        \\}
    ;
    var checklist = try coverage.build(allocator, "fixture.zig", source, "plain");
    defer checklist.deinit();

    try std.testing.expectEqual(@as(usize, 1), checklist.paths.len);
    try std.testing.expectEqualStrings("plain:entered", checklist.paths[0].name);
    try std.testing.expectEqual(@as(u32, 2), checklist.paths[0].witness);
    try std.testing.expect(!checklist.allTicked());
}

test "a function with an empty body has no code path and counts as complete" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", "fn nothing() void {}", "nothing");
    defer checklist.deinit();

    try std.testing.expectEqual(@as(usize, 0), checklist.paths.len);
    try std.testing.expect(checklist.allTicked());
    try std.testing.expectEqual(@as(usize, 0), checklist.unprovable);
}

test "a function whose whole body is on one line has no entry line to prove it" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", "fn one() u8 { return 1; }", "one");
    defer checklist.deinit();

    try std.testing.expectEqual(@as(usize, 0), checklist.paths.len);
    try std.testing.expectEqual(@as(usize, 1), checklist.unprovable);
}

test "build reports an error for a function name not in the source" {
    try std.testing.expectError(
        error.FunctionNotFound,
        coverage.build(std.testing.allocator, "fixture.zig", fixture_source, "doesNotExist"),
    );
}

test "build reports an error for text that does not parse as Zig" {
    try std.testing.expectError(
        error.SourceDoesNotParse,
        coverage.build(std.testing.allocator, "fixture.zig", "fn broken( {", "broken"),
    );
}

// Two functions sharing a name because each sits in a different container. `build` can only find
// the first one and `buildOccurrence` tells the second apart.
const duplicate_name_source =
    \\const First = struct {
    \\    fn shared(value: i64) i64 {
    \\        return value;
    \\    }
    \\};
    \\const Second = struct {
    \\    fn shared(value: i64) i64 {
    \\        if (value > 0) {
    \\            return value;
    \\        }
    \\        return 0;
    \\    }
    \\};
;

test "build always finds the first declaration sharing a name" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", duplicate_name_source, "shared");
    defer checklist.deinit();

    // `First.shared` has no branch, so its checklist is its entry alone.
    try std.testing.expectEqual(@as(usize, 1), checklist.paths.len);
    try std.testing.expectEqualStrings("shared:entered", checklist.paths[0].name);
}

test "buildOccurrence reads the second declaration sharing a name" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.buildOccurrence(allocator, "fixture.zig", duplicate_name_source, "shared", 1);
    defer checklist.deinit();

    // Its entry, the true side of its `if` and the false side, which the `return` after the `if`
    // proves because the taken side leaves.
    try std.testing.expectEqual(@as(usize, 3), checklist.paths.len);
    try std.testing.expectEqual(@as(u32, 11), try witnessOf(checklist, "if:8:false"));
}

test "buildOccurrence zero is the same declaration build finds" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.buildOccurrence(allocator, "fixture.zig", duplicate_name_source, "shared", 0);
    defer checklist.deinit();

    try std.testing.expectEqual(@as(usize, 1), checklist.paths.len);
}

test "buildOccurrence reports an error past the last declaration sharing a name" {
    try std.testing.expectError(
        error.FunctionNotFound,
        coverage.buildOccurrence(std.testing.allocator, "fixture.zig", duplicate_name_source, "shared", 2),
    );
}

test "listDeclarations lists every function, numbering same-named ones by occurrence" {
    const allocator = std.testing.allocator;
    const declarations = try coverage.listDeclarations(allocator, duplicate_name_source);
    defer coverage.freeDeclarations(allocator, declarations);

    try std.testing.expectEqual(@as(usize, 2), declarations.len);
    try std.testing.expectEqualStrings("shared", declarations[0].name);
    try std.testing.expectEqual(@as(usize, 0), declarations[0].occurrence);
    try std.testing.expectEqual(@as(u32, 2), declarations[0].line);
    try std.testing.expectEqualStrings("shared", declarations[1].name);
    try std.testing.expectEqual(@as(usize, 1), declarations[1].occurrence);
    try std.testing.expectEqual(@as(u32, 7), declarations[1].line);
}

test "listDeclarations says which functions are public" {
    const allocator = std.testing.allocator;
    const source =
        \\pub fn open() void {}
        \\fn hidden() void {}
    ;
    const declarations = try coverage.listDeclarations(allocator, source);
    defer coverage.freeDeclarations(allocator, declarations);

    try std.testing.expectEqual(@as(usize, 2), declarations.len);
    try std.testing.expect(declarations[0].is_public);
    try std.testing.expect(!declarations[1].is_public);
}

test "listDeclarations leaves out a function that returns type and still numbers the others the way build does" {
    const allocator = std.testing.allocator;
    const source =
        \\fn same(comptime T: type) type {
        \\    return T;
        \\}
        \\const Holder = struct {
        \\    fn same(value: i64) i64 {
        \\        return value;
        \\    }
        \\};
    ;
    const declarations = try coverage.listDeclarations(allocator, source);
    defer coverage.freeDeclarations(allocator, declarations);

    try std.testing.expectEqual(@as(usize, 1), declarations.len);
    try std.testing.expectEqual(@as(usize, 1), declarations[0].occurrence);

    // The occurrence it reports is the one `buildOccurrence` needs to read that same function.
    var checklist = try coverage.buildOccurrence(allocator, "fixture.zig", source, "same", declarations[0].occurrence);
    defer checklist.deinit();
    try std.testing.expectEqual(@as(u32, 6), checklist.paths[0].witness);
}

test "listDeclarations reports an error for text that does not parse as Zig" {
    try std.testing.expectError(
        error.SourceDoesNotParse,
        coverage.listDeclarations(std.testing.allocator, "fn broken( {"),
    );
}

// One Zig control-flow form per fixture, so what the walk sees of the language is a table a reader
// can check. `branch_sides` is how many branch sides the function has beyond its own entry,
// counting the ones no line can prove, which are counted in `Checklist.unprovable` and not in
// `paths`. A form the walk cannot see produces fewer and fails here.
const FormCase = struct {
    // What the fixture shows.
    form: []const u8,

    // A function named `sample`.
    source: [:0]const u8,

    // Branch sides beyond the entry.
    branch_sides: usize,
};

const form_cases = [_]FormCase{
    .{
        .form = "if statement, both sides written",
        .branch_sides = 2,
        .source =
        \\fn sample(flag: bool) void {
        \\    if (flag) {
        \\        one();
        \\    } else {
        \\        two();
        \\    }
        \\}
        ,
    },
    .{
        .form = "if statement with no else",
        .branch_sides = 2,
        .source =
        \\fn sample(flag: bool) void {
        \\    if (flag) {
        \\        one();
        \\    }
        \\}
        ,
    },
    .{
        .form = "if with an optional capture",
        .branch_sides = 2,
        .source =
        \\fn sample(value: ?u8) void {
        \\    if (value) |inner| {
        \\        one(inner);
        \\    }
        \\}
        ,
    },
    .{
        .form = "if with an error union capture and an else capture",
        .branch_sides = 2,
        .source =
        \\fn sample() void {
        \\    if (call()) |value| {
        \\        one(value);
        \\    } else |err| {
        \\        two(err);
        \\    }
        \\}
        ,
    },
    .{
        .form = "if used as a value",
        .branch_sides = 2,
        .source =
        \\fn sample(flag: bool) u8 {
        \\    const chosen = if (flag) one() else two();
        \\    return chosen;
        \\}
        ,
    },
    .{
        .form = "switch statement with an else prong",
        .branch_sides = 3,
        .source =
        \\fn sample(choice: u8) void {
        \\    switch (choice) {
        \\        1 => one(),
        \\        2 => two(),
        \\        else => other(),
        \\    }
        \\}
        ,
    },
    .{
        .form = "switch used as a value",
        .branch_sides = 3,
        .source =
        \\fn sample(choice: u8) u8 {
        \\    return switch (choice) {
        \\        1 => one(),
        \\        2 => two(),
        \\        else => other(),
        \\    };
        \\}
        ,
    },
    .{
        .form = "switch with a range prong and a multi-value prong",
        .branch_sides = 3,
        .source =
        \\fn sample(choice: u8) u8 {
        \\    return switch (choice) {
        \\        0...9 => one(),
        \\        10, 11 => two(),
        \\        else => other(),
        \\    };
        \\}
        ,
    },
    .{
        .form = "while loop",
        .branch_sides = 1,
        .source =
        \\fn sample(count: usize) void {
        \\    var index: usize = 0;
        \\    while (index < count) : (index += 1) {
        \\        work();
        \\    }
        \\}
        ,
    },
    .{
        .form = "while loop with a capture",
        .branch_sides = 1,
        .source =
        \\fn sample(source: anytype) void {
        \\    while (source.next()) |item| {
        \\        work(item);
        \\    }
        \\}
        ,
    },
    .{
        .form = "for loop",
        .branch_sides = 1,
        .source =
        \\fn sample(items: []const u8) void {
        \\    for (items) |item| {
        \\        work(item);
        \\    }
        \\}
        ,
    },
    .{
        .form = "catch with a capture",
        .branch_sides = 1,
        .source =
        \\fn sample() void {
        \\    call() catch |err| {
        \\        handle(err);
        \\    };
        \\}
        ,
    },
    .{
        .form = "catch used as a value",
        .branch_sides = 1,
        .source =
        \\fn sample() u8 {
        \\    const value = call() catch 0;
        \\    return value;
        \\}
        ,
    },
    .{
        .form = "orelse",
        .branch_sides = 1,
        .source =
        \\fn sample(value: ?u8) u8 {
        \\    return value orelse 0;
        \\}
        ,
    },
    .{
        .form = "try is not a branch side",
        .branch_sides = 0,
        .source =
        \\fn sample() !u8 {
        \\    const value = try call();
        \\    return value;
        \\}
        ,
    },
    .{
        .form = "and is not a branch side",
        .branch_sides = 0,
        .source =
        \\fn sample(first: bool, second: bool) bool {
        \\    return first and second;
        \\}
        ,
    },
    .{
        .form = "or is not a branch side",
        .branch_sides = 0,
        .source =
        \\fn sample(first: bool, second: bool) bool {
        \\    return first or second;
        \\}
        ,
    },
    .{
        .form = "branch inside a catch body",
        .branch_sides = 3,
        .source =
        \\fn sample() u8 {
        \\    return call() catch |err| {
        \\        if (err == error.Missing) {
        \\            return 1;
        \\        }
        \\        return 2;
        \\    };
        \\}
        ,
    },
    .{
        .form = "branch inside a defer body",
        .branch_sides = 2,
        .source =
        \\fn sample(flag: bool) void {
        \\    defer {
        \\        if (flag) {
        \\            one();
        \\        }
        \\    }
        \\    work();
        \\}
        ,
    },
    .{
        .form = "branch inside an errdefer body",
        .branch_sides = 2,
        .source =
        \\fn sample(flag: bool) !void {
        \\    errdefer {
        \\        if (flag) {
        \\            one();
        \\        }
        \\    }
        \\    try work();
        \\}
        ,
    },
    .{
        .form = "loop with an else clause",
        .branch_sides = 4,
        .source =
        \\fn sample(items: []const u8) u8 {
        \\    for (items) |item| {
        \\        if (item == 1) break;
        \\    } else {
        \\        return 0;
        \\    }
        \\    return 1;
        \\}
        ,
    },
    .{
        .form = "labelled block broken out of with a value",
        .branch_sides = 2,
        .source =
        \\fn sample(flag: bool) u8 {
        \\    return blk: {
        \\        if (flag) break :blk 1;
        \\        break :blk 2;
        \\    };
        \\}
        ,
    },
    .{
        .form = "inline for",
        .branch_sides = 1,
        .source =
        \\fn sample(comptime items: []const u8) void {
        \\    inline for (items) |item| {
        \\        work(item);
        \\    }
        \\}
        ,
    },
    .{
        .form = "switch inside a catch capture",
        .branch_sides = 3,
        .source =
        \\fn sample() u8 {
        \\    return call() catch |err| switch (err) {
        \\        error.Missing => 1,
        \\        else => 2,
        \\    };
        \\}
        ,
    },
};

test "the walk sees every Zig control-flow form" {
    const allocator = std.testing.allocator;
    var missed: usize = 0;
    for (form_cases) |form_case| {
        var checklist = try coverage.build(allocator, "fixture.zig", form_case.source, "sample");
        defer checklist.deinit();

        // Every function in the table has a first statement on its own line, so its entry is
        // always provable and always in `paths`.
        const found = checklist.paths.len + checklist.unprovable - 1;
        if (found != form_case.branch_sides) {
            missed += 1;
            std.debug.print(
                "form not seen as expected: {s}: expected {d} branch side(s), found {d}\n",
                .{ form_case.form, form_case.branch_sides, found },
            );
            for (checklist.paths) |path| {
                std.debug.print("    line {d} \"{s}\"\n", .{ path.line, path.name });
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missed);
}

test "and, or and try never appear among the code paths" {
    const allocator = std.testing.allocator;
    const source =
        \\fn sample(first: bool, second: bool) !u8 {
        \\    const both = first and second;
        \\    const either = first or second;
        \\    const value = try call();
        \\    return value + @intFromBool(both) + @intFromBool(either);
        \\}
    ;
    var checklist = try coverage.build(allocator, "fixture.zig", source, "sample");
    defer checklist.deinit();

    try std.testing.expectEqual(@as(usize, 1), checklist.paths.len);
    try std.testing.expectEqual(@as(usize, 0), checklist.unprovable);
    for (coverage.synthesized_kinds) |kind| {
        try std.testing.expect(!std.mem.eql(u8, kind, "and:"));
        try std.testing.expect(!std.mem.eql(u8, kind, "or:"));
        try std.testing.expect(!std.mem.eql(u8, kind, "try:"));
    }
}

test "a branch whose body is unreachable is not a code path" {
    const allocator = std.testing.allocator;
    const source =
        \\fn sample(flag: bool, choice: u8) u8 {
        \\    if (flag) {
        \\        unreachable;
        \\    } else {
        \\        one();
        \\    }
        \\    return switch (choice) {
        \\        1 => 1,
        \\        else => @panic("never"),
        \\    };
        \\}
    ;
    var checklist = try coverage.build(allocator, "fixture.zig", source, "sample");
    defer checklist.deinit();

    try std.testing.expect(pathNamed(checklist, "if:2:true") == null);
    try std.testing.expect(pathNamed(checklist, "if:4:false") != null);
    try std.testing.expect(pathNamed(checklist, "switch:8:1") != null);
    try std.testing.expect(pathNamed(checklist, "switch:9:else") == null);
}

test "a function declared inside another is not read into the outer checklist" {
    const allocator = std.testing.allocator;
    const source =
        \\fn outer(flag: bool) u8 {
        \\    const Inner = struct {
        \\        fn inner(value: bool) u8 {
        \\            if (value) {
        \\                return 1;
        \\            }
        \\            return 0;
        \\        }
        \\    };
        \\    if (flag) {
        \\        return Inner.inner(flag);
        \\    }
        \\    return 2;
        \\}
    ;
    var outer = try coverage.build(allocator, "fixture.zig", source, "outer");
    defer outer.deinit();
    var inner = try coverage.build(allocator, "fixture.zig", source, "inner");
    defer inner.deinit();

    try std.testing.expect(pathNamed(outer, "if:4:true") == null);
    try std.testing.expect(pathNamed(outer, "if:10:true") != null);
    try std.testing.expect(pathNamed(inner, "if:4:true") != null);
    try std.testing.expect(pathNamed(inner, "if:10:true") == null);
}

// One function holding every form a witness line is worked out for, each on lines the tests name.
const witness_source =
    \\fn sample(flag: bool, count: usize, choice: u8, items: []const u8) !u8 {
    \\    if (flag) {
    \\        one();
    \\    } else {
    \\        two();
    \\    }
    \\    if (count == 0) return 1;
    \\    after();
    \\    if (count == 1) {
    \\        carryOn();
    \\    }
    \\    switch (choice) {
    \\        1 => {
    \\            caseOne();
    \\        },
    \\        2 => caseTwo(),
    \\        else => caseElse(),
    \\    }
    \\    for (items) |item| {
    \\        work(item);
    \\    } else {
    \\        finished();
    \\    }
    \\    const value = call() catch |err| {
    \\        return fallback(err);
    \\    };
    \\    const other = maybe() orelse 0;
    \\    const both = flag and value > 0;
    \\    const read = try reading();
    \\    return value + other + read + @intFromBool(both);
    \\}
;

test "every code path carries the line that proves it" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", witness_source, "sample");
    defer checklist.deinit();

    try std.testing.expectEqual(@as(u32, 2), try witnessOf(checklist, "sample:entered"));
    try std.testing.expectEqual(@as(u32, 3), try witnessOf(checklist, "if:2:true"));
    try std.testing.expectEqual(@as(u32, 5), try witnessOf(checklist, "if:4:false"));
    // The taken side returns, so `after()` on the next line runs only when the condition did not hold.
    try std.testing.expectEqual(@as(u32, 8), try witnessOf(checklist, "if:7:false"));
    try std.testing.expectEqual(@as(u32, 10), try witnessOf(checklist, "if:9:true"));
    try std.testing.expectEqual(@as(u32, 14), try witnessOf(checklist, "switch:13:1"));
    // A bare expression on a line below the `switch` has a line of its own.
    try std.testing.expectEqual(@as(u32, 16), try witnessOf(checklist, "switch:16:2"));
    try std.testing.expectEqual(@as(u32, 17), try witnessOf(checklist, "switch:17:else"));
    try std.testing.expectEqual(@as(u32, 20), try witnessOf(checklist, "loop:19:body"));
    try std.testing.expectEqual(@as(u32, 22), try witnessOf(checklist, "loop:21:completed"));
    try std.testing.expectEqual(@as(u32, 25), try witnessOf(checklist, "catch:24:taken"));
}

test "a body on its condition's line and a side that carries on are left out and counted as unprovable" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", witness_source, "sample");
    defer checklist.deinit();

    // The body on the `if` line, the false side of an `if` whose taken side carries on and the
    // fallback on the line of its `orelse`.
    try std.testing.expect(pathNamed(checklist, "if:7:true") == null);
    try std.testing.expect(pathNamed(checklist, "if:9:false") == null);
    try std.testing.expect(pathNamed(checklist, "orelse:27:taken") == null);
    try std.testing.expectEqual(@as(usize, 3), checklist.unprovable);

    // Left out of the count, so they can be neither ticked nor listed.
    var everything = try linesWith(allocator, &.{}, &.{ 2, 3, 5, 8, 10, 14, 16, 17, 20, 22, 25 });
    defer everything.deinit(allocator);
    checklist.tickFromLines(&everything);
    try std.testing.expect(checklist.allTicked());
    try std.testing.expectEqual(checklist.paths.len, checklist.tickedCount());
}

test "a line two code paths share proves neither of them and both are left out" {
    const allocator = std.testing.allocator;
    const source =
        \\fn sample(choice: u8) u8 {
        \\    return switch (choice) {
        \\        1 => one(), 2 => two(),
        \\        else => three(),
        \\    };
        \\}
    ;
    var checklist = try coverage.build(allocator, "fixture.zig", source, "sample");
    defer checklist.deinit();

    try std.testing.expect(pathNamed(checklist, "switch:3:1") == null);
    try std.testing.expect(pathNamed(checklist, "switch:3:2") == null);
    try std.testing.expectEqual(@as(u32, 4), try witnessOf(checklist, "switch:4:else"));
    try std.testing.expectEqual(@as(usize, 2), checklist.unprovable);
}

test "the false side of a last-statement if that returns has no witness and is left out" {
    const allocator = std.testing.allocator;
    const source =
        \\fn sample(flag: bool) void {
        \\    work();
        \\    if (flag) {
        \\        return;
        \\    }
        \\}
    ;
    var checklist = try coverage.build(allocator, "fixture.zig", source, "sample");
    defer checklist.deinit();

    try std.testing.expect(pathNamed(checklist, "if:3:false") == null);
    try std.testing.expectEqual(@as(usize, 1), checklist.unprovable);
    try std.testing.expectEqual(@as(u32, 4), try witnessOf(checklist, "if:3:true"));
}

test "tickFromLines ticks a code path whose witness ran and leaves one whose witness did not" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", witness_source, "sample");
    defer checklist.deinit();

    var lines = try linesWith(allocator, &.{ 2, 3, 5, 8, 14, 16 }, &.{ 2, 3, 8 });
    defer lines.deinit(allocator);
    checklist.tickFromLines(&lines);

    try std.testing.expect(isTicked(checklist, "sample:entered"));
    try std.testing.expect(isTicked(checklist, "if:2:true"));
    try std.testing.expect(isTicked(checklist, "if:7:false"));
    try std.testing.expect(!isTicked(checklist, "if:4:false"));
    try std.testing.expect(!isTicked(checklist, "switch:13:1"));
    try std.testing.expectEqual(@as(usize, 3), checklist.tickedCount());
    try std.testing.expectEqual(checklist.paths.len - 3, checklist.untickedCount());
    try std.testing.expect(!checklist.allTicked());
}

test "a second run's lines add to the ticks and never take one back" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", witness_source, "sample");
    defer checklist.deinit();

    var first = try linesWith(allocator, &.{ 2, 3 }, &.{ 2, 3 });
    defer first.deinit(allocator);
    var second = try linesWith(allocator, &.{ 2, 5 }, &.{5});
    defer second.deinit(allocator);
    checklist.tickFromLines(&first);
    checklist.tickFromLines(&second);

    try std.testing.expect(isTicked(checklist, "if:2:true"));
    try std.testing.expect(isTicked(checklist, "if:4:false"));
    try std.testing.expect(isTicked(checklist, "sample:entered"));
}

test "markMissingLines flags an unticked witness the build has no code for, and only that" {
    const allocator = std.testing.allocator;
    var checklist = try coverage.build(allocator, "fixture.zig", witness_source, "sample");
    defer checklist.deinit();

    // Line 14 is code that did not run, line 5 is not code at all and lines 2 and 3 ran.
    var lines = try linesWith(allocator, &.{ 2, 3, 14 }, &.{ 2, 3 });
    defer lines.deinit(allocator);
    checklist.tickFromLines(&lines);
    checklist.markMissingLines(&lines);

    try std.testing.expect(pathNamed(checklist, "if:4:false").?.line_missing);
    try std.testing.expect(!pathNamed(checklist, "switch:13:1").?.line_missing);
    // Ticked, so never flagged, whatever the code set says.
    try std.testing.expect(!pathNamed(checklist, "if:2:true").?.line_missing);
}

test "buildFile builds one checklist for every function the file declares" {
    const allocator = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\pub fn first(flag: bool) u8 {
        \\    if (flag) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        \\fn Make(comptime T: type) type {
        \\    return T;
        \\}
        \\const Holder = struct {
        \\    fn second() void {
        \\        work();
        \\    }
        \\};
    ;
    const checklists = try coverage.buildFile(allocator, "src/thing.zig", source);
    defer coverage.freeChecklists(allocator, checklists);

    try std.testing.expectEqual(@as(usize, 2), checklists.len);
    try std.testing.expectEqualStrings("first", checklists[0].function);
    try std.testing.expectEqualStrings("src/thing.zig", checklists[0].file);
    try std.testing.expectEqual(@as(usize, 3), checklists[0].paths.len);
    try std.testing.expectEqualStrings("second", checklists[1].function);
    try std.testing.expectEqual(@as(usize, 1), checklists[1].paths.len);
}

test "buildFile reports an error for text that does not parse as Zig" {
    try std.testing.expectError(
        error.SourceDoesNotParse,
        coverage.buildFile(std.testing.allocator, "src/thing.zig", "fn broken( {"),
    );
}

test "buildFile reads each of two same-named functions on its own" {
    const allocator = std.testing.allocator;
    const checklists = try coverage.buildFile(allocator, "fixture.zig", duplicate_name_source);
    defer coverage.freeChecklists(allocator, checklists);

    try std.testing.expectEqual(@as(usize, 2), checklists.len);
    try std.testing.expectEqual(@as(usize, 1), checklists[0].paths.len);
    try std.testing.expectEqual(@as(usize, 3), checklists[1].paths.len);
}

// kcov's cobertura text for the file `src/thing.zig`, in the form `covered_lines.zig` reads: lines
// 2 and 3 ran and line 6 has code that did not run.
const cobertura =
    \\<class name="thing_zig" filename="src/thing.zig" line-rate="0.5">
    \\<lines>
    \\<line number="2" hits="1"/>
    \\<line number="3" hits="1"/>
    \\<line number="6" hits="0"/>
    \\</lines>
    \\</class>
;

const thing_source =
    \\pub fn first(flag: bool) u8 {
    \\    if (flag) {
    \\        return 1;
    \\    }
    \\    return 0;
    \\}
;

test "tickFromCovered ticks a checklist from the file kcov reported for it" {
    const allocator = std.testing.allocator;
    const checklists = try coverage.buildFile(allocator, "src/thing.zig", thing_source);
    defer coverage.freeChecklists(allocator, checklists);

    var covered = try covered_lines.parseCobertura(allocator, cobertura);
    defer covered.deinit();
    coverage.tickFromCovered(checklists, &covered, "/cache/sources");

    // Lines 2 and 3 ran and the `return 0` on line 5 is the witness of the false side.
    try std.testing.expect(isTicked(checklists[0], "first:entered"));
    try std.testing.expect(isTicked(checklists[0], "if:2:true"));
    try std.testing.expect(!isTicked(checklists[0], "if:2:false"));
    // Line 5 was never listed, so the build had no code for it.
    try std.testing.expect(pathNamed(checklists[0], "if:2:false").?.line_missing);
}

test "tickFromCovered leaves a checklist alone when kcov did not report its file" {
    const allocator = std.testing.allocator;
    const checklists = try coverage.buildFile(allocator, "src/other.zig", thing_source);
    defer coverage.freeChecklists(allocator, checklists);

    var covered = try covered_lines.parseCobertura(allocator, cobertura);
    defer covered.deinit();
    coverage.tickFromCovered(checklists, &covered, "/cache/sources");

    try std.testing.expectEqual(@as(usize, 0), checklists[0].tickedCount());
    try std.testing.expect(!pathNamed(checklists[0], "if:2:false").?.line_missing);
}

test "listUnticked names the file, line, function and code path of what is left" {
    const allocator = std.testing.allocator;
    const checklists = try coverage.buildFile(allocator, "src/thing.zig", thing_source);
    defer coverage.freeChecklists(allocator, checklists);

    var lines = try linesWith(allocator, &.{ 2, 3 }, &.{ 2, 3 });
    defer lines.deinit(allocator);
    checklists[0].tickFromLines(&lines);

    const unticked = try coverage.listUnticked(allocator, checklists);
    defer allocator.free(unticked);

    try std.testing.expectEqual(@as(usize, 1), unticked.len);
    try std.testing.expectEqualStrings("src/thing.zig", unticked[0].file);
    try std.testing.expectEqualStrings("first", unticked[0].function);
    try std.testing.expectEqual(@as(u32, 2), unticked[0].line);
    try std.testing.expectEqualStrings("if:2:false", unticked[0].name);
    try std.testing.expect(!unticked[0].line_missing);
}

test "listUnticked is empty when everything is ticked" {
    const allocator = std.testing.allocator;
    const checklists = try coverage.buildFile(allocator, "src/thing.zig", thing_source);
    defer coverage.freeChecklists(allocator, checklists);

    var lines = try linesWith(allocator, &.{}, &.{ 2, 3, 5 });
    defer lines.deinit(allocator);
    checklists[0].tickFromLines(&lines);

    const unticked = try coverage.listUnticked(allocator, checklists);
    defer allocator.free(unticked);
    try std.testing.expectEqual(@as(usize, 0), unticked.len);
}

test "countPaths adds up ticked and total across checklists" {
    const allocator = std.testing.allocator;
    const checklists = try coverage.buildFile(allocator, "src/thing.zig", thing_source);
    defer coverage.freeChecklists(allocator, checklists);

    var lines = try linesWith(allocator, &.{}, &.{2});
    defer lines.deinit(allocator);
    checklists[0].tickFromLines(&lines);

    const counts = coverage.countPaths(checklists);
    try std.testing.expectEqual(@as(usize, 1), counts.ticked);
    try std.testing.expectEqual(@as(usize, 3), counts.total);

    const none = coverage.countPaths(&.{});
    try std.testing.expectEqual(@as(usize, 0), none.total);
}

test "percentageOf rounds down and reads a run with no code path as complete" {
    try std.testing.expectEqual(@as(usize, 100), coverage.percentageOf(0, 0));
    try std.testing.expectEqual(@as(usize, 100), coverage.percentageOf(7, 7));
    try std.testing.expectEqual(@as(usize, 0), coverage.percentageOf(0, 7));
    try std.testing.expectEqual(@as(usize, 99), coverage.percentageOf(199, 200));
    try std.testing.expectEqual(@as(usize, 66), coverage.percentageOf(2, 3));
}
