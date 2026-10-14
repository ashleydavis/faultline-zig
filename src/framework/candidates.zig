// Candidate values read from the conditions in one function's source. A condition such as
// `count > 100` or `std.mem.eql(u8, name, "stop")` tells Faultline which constant decides a branch,
// so the values worth trying are the constant and the values on each side of it. The list for a
// type is deterministic (it follows the order of the conditions) and has no repeats, so the same
// conditions always produce the same calls.

const std = @import("std");
const condition = @import("condition.zig");

// What is added to a string to make one that starts or ends with a literal. One character, because
// the point is that the string is longer than the literal and still matches it at one end.
const extra_text = "a";

// Whether a type can have candidates at all: integers, floats, booleans, enums, optionals and
// constant byte slices (strings). Every other type always gets an empty list.
pub fn isCandidateType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => true,
        .pointer => |info| info.size == .slice and info.child == u8 and info.is_const,
        else => false,
    };
}

// The candidate values of type `T` found in `conditions`, allocated from `allocator`. Numbers get
// the literal, one below and one above. Strings get the literal and a near miss and for a prefix
// or suffix test a string with the literal at that end and a near miss of that. Enums get each tag
// named. Booleans get both. An optional gets null first, then the candidates of what it holds,
// and has no list when neither a null test nor candidates for what it holds were found. A type with
// no candidates gets an empty list.
pub fn candidatesFor(comptime T: type, allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const T {
    switch (@typeInfo(T)) {
        .int => {
            return integerCandidates(T, allocator, conditions);
        },
        .float => {
            return floatCandidates(T, allocator, conditions);
        },
        .bool => {
            const both = try allocator.alloc(bool, 2);
            both[0] = false;
            both[1] = true;
            return both;
        },
        .@"enum" => {
            return enumCandidates(T, allocator, conditions);
        },
        .optional => |info| {
            return optionalCandidates(info.child, allocator, conditions);
        },
        .pointer => |info| {
            if (comptime info.size == .slice and info.child == u8 and info.is_const) {
                return sliceCandidates(T, allocator, conditions);
            }
            return &.{};
        },
        else => {
            return &.{};
        },
    }
}

// The strings found in `conditions`, in the order the conditions give them: for each string
// literal the literal and then a near miss and for a prefix or suffix test the two strings that
// carry it at that end. No string appears twice.
pub fn stringCandidates(allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const []const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    for (conditions) |found_condition| {
        const literal = found_condition.literal orelse {
            continue;
        };
        if (literal != .string) {
            continue;
        }
        const text = literal.string;
        const near = try nearMiss(allocator, text);
        try addString(allocator, &found, text);
        try addString(allocator, &found, near);
        switch (found_condition.kind) {
            .string_starts_with => {
                try addString(allocator, &found, try std.mem.concat(allocator, u8, &.{ text, extra_text }));
                try addString(allocator, &found, try std.mem.concat(allocator, u8, &.{ near, extra_text }));
            },
            .string_ends_with => {
                try addString(allocator, &found, try std.mem.concat(allocator, u8, &.{ extra_text, text }));
                try addString(allocator, &found, try std.mem.concat(allocator, u8, &.{ extra_text, near }));
            },
            else => {},
        }
    }
    return found.items;
}

// A string that differs from `text` by one bit of its last byte, so it is as long and almost the
// same and never equal to it. The empty string has no last byte, so its near miss is one letter.
pub fn nearMiss(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]u8 {
    if (text.len == 0) {
        return allocator.dupe(u8, extra_text);
    }
    const near = try allocator.dupe(u8, text);
    near[near.len - 1] ^= 1;
    return near;
}

// Adds a string to the list unless the list already holds it.
fn addString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8) error{OutOfMemory}!void {
    for (list.items) |earlier| {
        if (std.mem.eql(u8, earlier, text)) {
            return;
        }
    }
    try list.append(allocator, text);
}

// Whether a condition's literal is a number the value of an integer or floating point type could be
// compared against.
fn isNumber(literal: condition.Literal) bool {
    return literal == .int or literal == .float;
}

// The literal, one below it and one above it for every integer literal, skipping any the type
// cannot hold.
fn integerCandidates(comptime T: type, allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const T {
    var found: std.ArrayList(T) = .empty;
    for (conditions) |found_condition| {
        const literal = found_condition.literal orelse {
            continue;
        };
        if (literal != .int) {
            continue;
        }
        const middle = literal.int;
        const sides = [_]?i128{
            middle,
            std.math.sub(i128, middle, 1) catch null,
            std.math.add(i128, middle, 1) catch null,
        };
        for (sides) |side| {
            const value = side orelse {
                continue;
            };
            const fitted = std.math.cast(T, value) orelse {
                continue;
            };
            try addDistinct(T, allocator, &found, fitted);
        }
    }
    return found.items;
}

// The literal and the next representable number on each side of it for every numeric literal. An
// integer literal compared against a float is taken as that float.
fn floatCandidates(comptime T: type, allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const T {
    var found: std.ArrayList(T) = .empty;
    for (conditions) |found_condition| {
        const literal = found_condition.literal orelse {
            continue;
        };
        if (!isNumber(literal)) {
            continue;
        }
        const middle: T = switch (literal) {
            .int => |whole| @floatFromInt(whole),
            .float => |fraction| @floatCast(fraction),
            else => unreachable,
        };
        if (!std.math.isFinite(middle)) {
            continue;
        }
        try addDistinct(T, allocator, &found, middle);
        try addDistinct(T, allocator, &found, std.math.nextAfter(T, middle, -std.math.inf(T)));
        try addDistinct(T, allocator, &found, std.math.nextAfter(T, middle, std.math.inf(T)));
    }
    return found.items;
}

// Each tag of the enum that a condition names, in the order the conditions name them. A name the
// enum does not have is ignored.
fn enumCandidates(comptime T: type, allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const T {
    var found: std.ArrayList(T) = .empty;
    for (conditions) |found_condition| {
        const literal = found_condition.literal orelse {
            continue;
        };
        if (literal != .enum_tag) {
            continue;
        }
        const tag = std.meta.stringToEnum(T, literal.enum_tag) orelse {
            continue;
        };
        try addDistinct(T, allocator, &found, tag);
    }
    return found.items;
}

// Null, then each candidate of the held type. An optional with no null test and no candidate for
// what it holds has no list: the boundary values already hold null and a value.
fn optionalCandidates(comptime Child: type, allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const ?Child {
    const inner = try candidatesFor(Child, allocator, conditions);
    var has_null_test = false;
    for (conditions) |found_condition| {
        const is_null_literal = if (found_condition.literal) |literal| literal == .null_value else false;
        if (found_condition.kind == .optional_check or is_null_literal) {
            has_null_test = true;
        }
    }
    if (inner.len == 0 and !has_null_test) {
        return &.{};
    }
    const list = try allocator.alloc(?Child, inner.len + 1);
    list[0] = null;
    for (inner, 0..) |value, index| {
        list[index + 1] = value;
    }
    return list;
}

// A string type's candidates: the strings above, copied with a sentinel when the type has one.
fn sliceCandidates(comptime T: type, allocator: std.mem.Allocator, conditions: []const condition.Condition) error{OutOfMemory}![]const T {
    const strings = try stringCandidates(allocator, conditions);
    const list = try allocator.alloc(T, strings.len);
    for (strings, 0..) |text, index| {
        if (comptime @typeInfo(T).pointer.sentinel() != null) {
            const sentinel = comptime @typeInfo(T).pointer.sentinel().?;
            const room = try allocator.allocSentinel(u8, text.len, sentinel);
            @memcpy(room, text);
            list[index] = room;
        } else {
            list[index] = text;
        }
    }
    return list;
}

// Adds a value unless the list already holds an equal one. Numbers compare by value, so the two
// zeros of a float are one.
fn addDistinct(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(T), value: T) error{OutOfMemory}!void {
    for (list.items) |earlier| {
        if (earlier == value) {
            return;
        }
    }
    try list.append(allocator, value);
}

test {
    _ = @import("candidates.test.zig");
}
