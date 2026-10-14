const std = @import("std");
const covered_lines = @import("covered_lines.zig");

// Two files the way kcov 43 writes them with `--cobertura-only`: the class carries the filename,
// each line carries a number and a hit count, and everything around them is passed over.
const fixture =
    \\<?xml version="1.0" ?>
    \\<!DOCTYPE coverage SYSTEM 'http://cobertura.sourceforge.net/xml/coverage-04.dtd'>
    \\<coverage line-rate="0.5" branch-rate="1.0" version="1.9" timestamp="1">
    \\    <sources>
    \\        <source>/somewhere/</source>
    \\    </sources>
    \\    <packages>
    \\        <package name="o" line-rate="0.5" branch-rate="1.0" complexity="1.0">
    \\            <classes>
    \\                <class name="branching_zig__1" filename="o/abc/branching.zig" branch-rate="1.0" complexity="1.0" line-rate="0.5">
    \\                    <lines>
    \\                        <line number="10" hits="1"/>
    \\                        <line number="11" hits="0"/>
    \\                        <line number="22" hits="3"/>
    \\                    </lines>
    \\                </class>
    \\                <class name="other_zig__2" filename="o/abc/nested/other.zig" branch-rate="1.0" complexity="1.0" line-rate="0.5">
    \\                    <lines>
    \\                        <line number="4" hits="1"/>
    \\                    </lines>
    \\                </class>
    \\            </classes>
    \\        </package>
    \\    </packages>
    \\</coverage>
;

test "parseCobertura reads every file and its lines" {
    var lines = try covered_lines.parseCobertura(std.testing.allocator, fixture);
    defer lines.deinit();

    try std.testing.expectEqual(@as(usize, 2), lines.files.count());

    const branching = lines.linesFor("/somewhere/o/abc", "branching.zig") orelse return error.FileNotReported;
    try std.testing.expect(branching.isHit(10));
    try std.testing.expect(branching.isHit(22));
    try std.testing.expect(!branching.isHit(11));

    const other = lines.linesFor("/somewhere/o/abc", "nested/other.zig") orelse return error.FileNotReported;
    try std.testing.expect(other.isHit(4));
}

test "a line with no hits is code but not hit, and a line never listed is neither" {
    var lines = try covered_lines.parseCobertura(std.testing.allocator, fixture);
    defer lines.deinit();

    const branching = lines.linesFor("/somewhere/o/abc", "branching.zig") orelse return error.FileNotReported;
    try std.testing.expect(branching.isCode(11));
    try std.testing.expect(!branching.isHit(11));
    try std.testing.expect(!branching.isCode(12));
    try std.testing.expect(!branching.isHit(12));
}

test "linesFor matches the reported name against the end of the copy's path" {
    var lines = try covered_lines.parseCobertura(std.testing.allocator, fixture);
    defer lines.deinit();

    // The reported name is the whole of the copy's path once the shared prefix is added back.
    try std.testing.expect(lines.linesFor("/somewhere/o/abc", "branching.zig") != null);
    // A different root that still ends the same way matches too, since kcov strips whatever
    // prefix every reported file shares.
    try std.testing.expect(lines.linesFor("/elsewhere/o/abc", "branching.zig") != null);
    // A file that only shares a tail of its name is not the same file.
    try std.testing.expect(lines.linesFor("/somewhere/o/abc", "xbranching.zig") == null);
    // A file kcov never reported.
    try std.testing.expect(lines.linesFor("/somewhere/o/abc", "missing.zig") == null);
}

test "isSameFile takes a whole path and a suffix at a slash, and refuses a suffix inside a name" {
    try std.testing.expect(covered_lines.isSameFile("/root/o/abc", "a.zig", "/root/o/abc/a.zig"));
    try std.testing.expect(covered_lines.isSameFile("/root/o/abc", "a.zig", "abc/a.zig"));
    try std.testing.expect(covered_lines.isSameFile("/root/o/abc", "a.zig", "a.zig"));
    try std.testing.expect(!covered_lines.isSameFile("/root/o/abc", "a.zig", "bc/a.zig"));
    try std.testing.expect(!covered_lines.isSameFile("/root/o/abc", "a.zig", "/other/o/abc/a.zig"));
}

test "text with no class, or a line with no number, gives an empty set rather than an error" {
    var no_class = try covered_lines.parseCobertura(std.testing.allocator, "<coverage>\n<line number=\"3\" hits=\"1\"/>\n</coverage>\n");
    defer no_class.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_class.files.count());

    var no_number = try covered_lines.parseCobertura(std.testing.allocator, "<class filename=\"a.zig\">\n<line hits=\"1\"/>\n</class>\n");
    defer no_number.deinit();
    const set = no_number.linesFor("/r", "a.zig") orelse return error.FileNotReported;
    try std.testing.expectEqual(@as(usize, 0), set.code.count());
}

test "a file reported twice has its lines merged" {
    const twice =
        \\<class filename="a.zig">
        \\<line number="1" hits="1"/>
        \\</class>
        \\<class filename="a.zig">
        \\<line number="2" hits="0"/>
        \\</class>
    ;
    var lines = try covered_lines.parseCobertura(std.testing.allocator, twice);
    defer lines.deinit();
    try std.testing.expectEqual(@as(usize, 1), lines.files.count());
    const set = lines.linesFor("/r", "a.zig") orelse return error.FileNotReported;
    try std.testing.expect(set.isHit(1));
    try std.testing.expect(set.isCode(2));
    try std.testing.expect(!set.isHit(2));
}

test "readCobertura on a file that is not there says the coverage file is missing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(
        error.CoverageFileMissing,
        covered_lines.readCobertura(std.testing.allocator, threaded.io(), "tmp/no-such-directory/cov.xml"),
    );
}
