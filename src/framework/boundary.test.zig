const std = @import("std");
const boundary = @import("boundary.zig");

test "a signed integer type lists zero, one, minus one, minimum and maximum in that order" {
    try std.testing.expectEqualSlices(i8, &.{ 0, 1, -1, -128, 127 }, boundary.boundaryIntegers(i8));
}

test "an unsigned integer type has no minus one and its minimum is the zero already listed" {
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 255 }, boundary.boundaryIntegers(u8));
}

test "a type too narrow for a boundary value leaves it out" {
    try std.testing.expectEqualSlices(u1, &.{ 0, 1 }, boundary.boundaryIntegers(u1));
    try std.testing.expectEqualSlices(i1, &.{ 0, -1 }, boundary.boundaryIntegers(i1));
    try std.testing.expectEqualSlices(u0, &.{0}, boundary.boundaryIntegers(u0));
}

test "the widest integer types list their true minimum and maximum" {
    const list = boundary.boundaryIntegers(i128);
    try std.testing.expectEqual(@as(i128, std.math.minInt(i128)), list[3]);
    try std.testing.expectEqual(@as(i128, std.math.maxInt(i128)), list[4]);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), boundary.boundaryIntegers(u64)[2]);
}

test "a floating point type lists zero, one, minus one and the finite extremes" {
    const list = boundary.boundaryFloats(f32);
    try std.testing.expectEqual(@as(usize, 5), list.len);
    try std.testing.expectEqual(@as(f32, 0), list[0]);
    try std.testing.expectEqual(@as(f32, 1), list[1]);
    try std.testing.expectEqual(@as(f32, -1), list[2]);
    try std.testing.expectEqual(-std.math.floatMax(f32), list[3]);
    try std.testing.expectEqual(std.math.floatMax(f32), list[4]);
    for (boundary.boundaryFloats(f64)) |value| {
        try std.testing.expect(std.math.isFinite(value));
    }
}

test "every tag of an enum is listed in declaration order" {
    const Colour = enum { red, green, blue };
    try std.testing.expectEqualSlices(Colour, &.{ .red, .green, .blue }, boundary.boundaryTags(Colour));

    const Sparse = enum(u8) { low = 3, high = 200 };
    try std.testing.expectEqualSlices(Sparse, &.{ .low, .high }, boundary.boundaryTags(Sparse));
}

test "the boundary strings are the empty string and a one character string" {
    try std.testing.expectEqual(@as(usize, 2), boundary.boundary_strings.len);
    try std.testing.expectEqualStrings("", boundary.boundary_strings[0]);
    try std.testing.expectEqual(@as(usize, 1), boundary.boundary_strings[1].len);
}

test "mixing the seed is the same every time and differs by seed, position and index" {
    try std.testing.expectEqual(boundary.mixSeed(7, 1, 2), boundary.mixSeed(7, 1, 2));
    try std.testing.expect(boundary.mixSeed(7, 1, 2) != boundary.mixSeed(8, 1, 2));
    try std.testing.expect(boundary.mixSeed(7, 1, 2) != boundary.mixSeed(7, 2, 2));
    try std.testing.expect(boundary.mixSeed(7, 1, 2) != boundary.mixSeed(7, 1, 3));
    try std.testing.expect(boundary.mixSeed(7, 1, 2) != boundary.mixSeed(7, 2, 1));
}

test "the same seed gives the same integers, floats, lengths and text" {
    var first = std.Random.DefaultPrng.init(boundary.mixSeed(99, 0, 0));
    var second = std.Random.DefaultPrng.init(boundary.mixSeed(99, 0, 0));
    for (0..20) |_| {
        try std.testing.expectEqual(boundary.seededInteger(i32, first.random()), boundary.seededInteger(i32, second.random()));
        try std.testing.expectEqual(boundary.seededFloat(f64, first.random()), boundary.seededFloat(f64, second.random()));
        try std.testing.expectEqual(boundary.seededLength(first.random()), boundary.seededLength(second.random()));
    }

    var third = std.Random.DefaultPrng.init(5);
    var fourth = std.Random.DefaultPrng.init(5);
    const one = try boundary.seededText(std.testing.allocator, third.random());
    defer std.testing.allocator.free(one);
    const two = try boundary.seededText(std.testing.allocator, fourth.random());
    defer std.testing.allocator.free(two);
    try std.testing.expectEqualStrings(one, two);
}

test "different seeds give different integers" {
    var first = std.Random.DefaultPrng.init(boundary.mixSeed(1, 0, 0));
    var second = std.Random.DefaultPrng.init(boundary.mixSeed(2, 0, 0));
    var differed = false;
    for (0..20) |_| {
        if (boundary.seededInteger(u64, first.random()) != boundary.seededInteger(u64, second.random())) {
            differed = true;
        }
    }
    try std.testing.expect(differed);
}

test "a seeded integer always fits its type, including the narrow ones" {
    var prng = std.Random.DefaultPrng.init(3);
    for (0..200) |_| {
        _ = boundary.seededInteger(u1, prng.random());
        _ = boundary.seededInteger(i1, prng.random());
        _ = boundary.seededInteger(u0, prng.random());
        const byte = boundary.seededInteger(u8, prng.random());
        try std.testing.expect(byte <= 255);
    }
}

test "seeded floats are finite and inside the stated range" {
    var prng = std.Random.DefaultPrng.init(11);
    for (0..200) |_| {
        const value = boundary.seededFloat(f32, prng.random());
        try std.testing.expect(value >= -1000 and value <= 1000);
    }
}

test "seeded lengths and text never exceed the longest and text is lower case letters" {
    var prng = std.Random.DefaultPrng.init(21);
    for (0..100) |_| {
        try std.testing.expect(boundary.seededLength(prng.random()) <= boundary.longest_seeded_length);
        const text = try boundary.seededText(std.testing.allocator, prng.random());
        defer std.testing.allocator.free(text);
        try std.testing.expect(text.len <= boundary.longest_seeded_length);
        for (text) |letter| {
            try std.testing.expect(letter >= 'a' and letter <= 'z');
        }
    }
}
