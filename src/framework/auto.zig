// Builds the values a function is called with from the types in its signature, with no scenario
// written for any of them. What a function takes is read off its signature at comptime. The
// allocator, `std.Io`, `std.Random` and a writer are supplied by the run. Integers, floats,
// booleans, enums, optionals, strings and slices, arrays, plain structs, tagged unions and
// pointers to those are built from their own type. A type that cannot be built that way is built
// by a value factory found in the sim file (see `locator.zig`).
//
// Every value that can be chosen for a parameter is named by a `Choice` (see `call_specs.zig`), so
// a replay token can carry the values chosen. A choice comes from one of four places: the fixed list
// of boundary values, a few values from the run's random number generator (seeded from the run's
// seed), the candidates read from the conditions in the function's source, or a value factory.
//
// Nothing here names a package's own types: every type but the supplied ones is decided by
// `@typeInfo`, or by a value factory.

const std = @import("std");
const condition = @import("condition.zig");
const boundary = @import("boundary.zig");
const candidates = @import("candidates.zig");
const call_specs = @import("call_specs.zig");

// The shared names for what a choice is made of.
pub const Choice = call_specs.Choice;
pub const Source = call_specs.Source;
pub const Spec = call_specs.Spec;

// How far into a type this looks before giving up. A type holding a pointer to itself (an error
// with a cause, a node with a parent) has no bottom, so the walk needs an end that does not depend
// on the type having one. Twelve is deeper than any real nesting of options, lists and pointers and
// shallow enough to stop a cycle at once.
pub const value_depth_limit = 12;

// The error handed to a parameter that takes an error set containing any error (`anyerror`). A
// narrower error set is handed its first error. Where the error decides a branch, as in a `switch`
// that words each error, value factories that return the error set give the others.
pub const supplied_error = error.SimSuppliedError;

// What a call under way is given. A context is copied freely: the pieces that change are behind
// pointers.
pub fn Context(comptime Locator: type) type {
    return struct {
        // What finds and runs value factories. Behind a pointer because struct factories keep state.
        locator: *Locator,

        // Where values built for a call live. The caller resets it between calls, so nothing a call
        // built has to be freed by hand and nothing survives into the next one.
        arena: std.mem.Allocator,

        // What the code under test allocates from.
        call_allocator: std.mem.Allocator,

        // The `Io` the code under test reads the clock, files and network through.
        io: std.Io,

        // The generator handed to a parameter of type `std.Random`.
        random: std.Random,

        // Somewhere for code that writes output to write it. A writer has to be a real one with
        // room behind it, so it is supplied like the allocator rather than built from its type.
        writer: *std.Io.Writer,

        // The seed of the run, carried in the replay token. Every seeded value is a pure function
        // of this, the parameter's position and the choice's index.
        seed: u64,

        // Which parameter a value is being built for, so two parameters of one type are not given
        // the same seeded value. The functions that build arguments set it.
        position: u32 = 0,

        // The conditions read from the function being called, whose values are the condition
        // choices. Empty until a code path needs them.
        conditions: []const condition.Condition = &.{},
    };
}

// Whether the run supplies this type itself: the allocator the code under test draws from, the `Io`
// it reads the clock and the network through, the random source and a writer.
pub fn isSupplied(comptime T: type) bool {
    return T == std.mem.Allocator or T == std.Io or T == std.Random or T == *std.Io.Writer or T == std.Io.Dir;
}

// Whether `T` is a list that owns its memory, such as `std.ArrayList(u8)`: a struct with `items`
// and `capacity` that starts from `empty` and grows with the allocator it is given. Building one
// field by field would make `items` memory no allocator handed out, and the first append would
// make the allocator resize memory that is not its own. So one is built from the elements of a
// slice, appended with the allocator the call is given.
pub fn isOwnedList(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") {
        return false;
    }
    return @hasField(T, "items") and @hasField(T, "capacity") and @hasDecl(T, "empty") and @hasDecl(T, "appendSlice");
}

// The slice an owned list's elements are built as.
fn ElementsOf(comptime T: type) type {
    return []@typeInfo(@FieldType(T, "items")).pointer.child;
}

// The files a parameter of type `std.Io.File` is given: the simulated standard input, for code
// that reads, and standard output, for code that writes. A file made from a number would be a
// handle the simulated filesystem never gave out, and its reads and writes would go to the real
// system.
fn boundaryFile(index: usize) std.Io.File {
    return if (index % 2 == 0) std.Io.File.stdin() else std.Io.File.stdout();
}

// Whether a value factory takes over from building this type from its own type. Not for the
// built-in leaf types (numbers, booleans, enums, optionals, strings): a helper function in a sim
// file that happens to return a `u32` must not replace every `u32` argument, so for those the
// factories are extra choices after the built-in ones.
fn isFactoryFirst(comptime T: type, comptime Locator: type) bool {
    return Locator.canMake(T) and !candidates.isCandidateType(T) and !isSupplied(T) and @typeInfo(T) != .error_set;
}

// Whether a struct field is built, as against left at its default. A default is the value the
// type's author says makes a whole one and a list or buffer built from independent draws is not
// one: its length and the memory it points at would have nothing to do with each other and the
// first thing to read it would fault. So a field with a default keeps it, except a field the run
// supplies or a field a value factory builds.
fn isBuiltField(comptime field: std.builtin.Type.StructField, comptime Locator: type) bool {
    if (field.is_comptime) {
        return false;
    }
    return field.defaultValue() == null or isSupplied(field.type) or isFactoryFirst(field.type, Locator);
}

// Whether every value of this type can be built here. A function taking one that cannot is left
// alone rather than called with something invented: a function pointer, an erased pointer or a
// type parameter has no value a signature alone decides.
pub fn canMakeValue(comptime T: type, comptime Locator: type) bool {
    return Answer(T, Locator).value;
}

// Zig instantiates a generic type once per set of arguments and keeps it, so a declaration inside
// one is computed once however often it is read. Without this the walk below runs again for every
// parameter of every function and it recurses through every field of every type it meets.
fn Answer(comptime T: type, comptime Locator: type) type {
    return struct {
        const value = canMakeValueTo(T, Locator, value_depth_limit);
    };
}

fn canMakeValueTo(comptime T: type, comptime Locator: type, comptime depth: usize) bool {
    if (isSupplied(T) or T == std.Io.File) {
        return true;
    }
    if (isOwnedList(T)) {
        return depth > 0 and canMakeValueTo(ElementsOf(T), Locator, depth - 1);
    }
    // A type nothing can be assembled out of can still be obtained by asking the sim file for one:
    // a value whose insides are function pointers is made by whatever makes it and this is how
    // the run reaches functions taking one.
    if (Locator.canMake(T)) {
        return true;
    }
    if (depth == 0) {
        return false;
    }
    return switch (@typeInfo(T)) {
        .int, .comptime_int, .float, .comptime_float, .bool, .void => true,
        .@"enum" => |info| info.fields.len > 0,
        .error_set => |errors| errors == null or errors.?.len > 0,
        .array => |info| info.sentinel_ptr == null and canMakeValueTo(info.child, Locator, depth - 1),
        .optional => |info| canMakeValueTo(info.child, Locator, depth - 1),
        .pointer => |info| switch (info.size) {
            .slice => canMakeValueTo(info.child, Locator, depth - 1),
            .one => canMakeValueTo(info.child, Locator, depth - 1),
            else => false,
        },
        .@"struct" => |info| blk: {
            if (info.layout == .@"extern" or info.layout == .@"packed") {
                break :blk false;
            }
            for (info.fields) |field| {
                if (isBuiltField(field, Locator) and !canMakeValueTo(field.type, Locator, depth - 1)) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        // A tagged union is one of its variants, so one buildable variant is enough: the ones that
        // cannot be built are simply never chosen. An untagged union has no way to say which
        // variant a value is, so nothing can build one safely.
        .@"union" => |info| blk: {
            if (info.tag_type == null) {
                break :blk false;
            }
            for (info.fields) |field| {
                if (canMakeValueTo(field.type, Locator, depth - 1)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        else => false,
    };
}

// How many boundary values a type has: the fixed list for a leaf type and for a type made of
// others as many as its largest part has, because the parts are stepped through together. An
// optional adds null. A slice has an empty one, a one element one and, when the callee may write
// into it, a roomy one.
fn boundaryCount(comptime T: type, comptime Locator: type, comptime depth: usize) usize {
    if (comptime isSupplied(T)) {
        return 1;
    }
    if (comptime isFactoryFirst(T, Locator)) {
        return Locator.count(T);
    }
    if (comptime T == std.Io.File) {
        return 2;
    }
    if (comptime isOwnedList(T)) {
        return sliceBoundaryCount(ElementsOf(T));
    }
    if (comptime depth == 0) {
        return 1;
    }
    return switch (@typeInfo(T)) {
        .bool => 2,
        .int => boundary.boundaryIntegers(T).len,
        .float => boundary.boundaryFloats(T).len,
        .@"enum" => boundary.boundaryTags(T).len,
        .optional => |info| 1 + boundaryCount(info.child, Locator, depth - 1),
        .array => |info| boundaryCount(info.child, Locator, depth - 1),
        .pointer => |info| switch (info.size) {
            .one => boundaryCount(info.child, Locator, depth - 1),
            .slice => sliceBoundaryCount(T),
            else => 1,
        },
        .@"struct" => |info| blk: {
            var most: usize = 1;
            for (info.fields) |field| {
                if (isBuiltField(field, Locator)) {
                    most = @max(most, boundaryCount(field.type, Locator, depth - 1));
                }
            }
            break :blk most;
        },
        .@"union" => |info| blk: {
            var total: usize = 0;
            for (info.fields) |field| {
                if (canMakeValue(field.type, Locator)) {
                    total += boundaryCount(field.type, Locator, depth - 1);
                }
            }
            break :blk @max(total, 1);
        },
        else => 1,
    };
}

// How many boundary values a slice type has: the strings for a constant byte slice and the
// lengths for any other slice.
fn sliceBoundaryCount(comptime T: type) usize {
    const info = @typeInfo(T).pointer;
    if (info.child == u8 and info.is_const) {
        return boundary.boundary_strings.len;
    }
    return if (info.is_const) 2 else 3;
}

// The length of the boundary slice at an index: empty, one element and for a slice the callee
// writes into, room for a short line.
fn sliceBoundaryLength(index: usize) usize {
    const lengths = [_]usize{ 0, 1, boundary.roomy_length };
    return lengths[index % lengths.len];
}

// How many values the conditions give for a type. For a type made of others it is as many as its
// largest part gives and no part giving any gives none.
fn conditionCount(comptime T: type, comptime Locator: type, ctx: Context(Locator), comptime depth: usize) anyerror!usize {
    if (comptime isSupplied(T) or isFactoryFirst(T, Locator) or depth == 0 or T == std.Io.File or isOwnedList(T)) {
        return 0;
    }
    if (comptime candidates.isCandidateType(T)) {
        return (try candidates.candidatesFor(T, ctx.arena, ctx.conditions)).len;
    }
    switch (@typeInfo(T)) {
        .array => |info| {
            return conditionCount(info.child, Locator, ctx, depth - 1);
        },
        .pointer => |info| {
            if (info.size == .one) {
                return conditionCount(info.child, Locator, ctx, depth - 1);
            }
            return 0;
        },
        .@"struct" => |info| {
            var most: usize = 0;
            inline for (info.fields) |field| {
                if (comptime isBuiltField(field, Locator)) {
                    most = @max(most, try conditionCount(field.type, Locator, ctx, depth - 1));
                }
            }
            return most;
        },
        .@"union" => |info| {
            var total: usize = 0;
            inline for (info.fields) |field| {
                if (comptime canMakeValue(field.type, Locator)) {
                    total += try conditionCount(field.type, Locator, ctx, depth - 1);
                }
            }
            return total;
        },
        else => {
            return 0;
        },
    }
}

// How many values a source offers for a type.
fn countFrom(comptime T: type, comptime Locator: type, ctx: Context(Locator), source: Source, comptime depth: usize) anyerror!usize {
    return switch (source) {
        .boundary => comptime boundaryCount(T, Locator, depth),
        .condition => try conditionCount(T, Locator, ctx, depth),
        .seeded, .factory => 1,
    };
}

// Whether the random number generator can make two values of this type differ. A type made only of
// fields left at their defaults has one value whatever the seed and offering it again and again
// would only repeat the same call.
fn isSeedVarying(comptime T: type, comptime Locator: type, comptime depth: usize) bool {
    if (comptime isSupplied(T)) {
        return false;
    }
    if (comptime T == std.Io.File or isOwnedList(T)) {
        return true;
    }
    if (comptime isFactoryFirst(T, Locator)) {
        return Locator.count(T) > 1;
    }
    if (comptime depth == 0) {
        return false;
    }
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .optional => true,
        .@"enum" => |info| info.fields.len > 1,
        .array => |info| info.len > 0 and isSeedVarying(info.child, Locator, depth - 1),
        .pointer => |info| switch (info.size) {
            .one => isSeedVarying(info.child, Locator, depth - 1),
            .slice => true,
            else => false,
        },
        .@"struct" => |info| blk: {
            for (info.fields) |field| {
                if (isBuiltField(field, Locator) and isSeedVarying(field.type, Locator, depth - 1)) {
                    break :blk true;
                }
            }
            break :blk false;
        },
        .@"union" => true,
        else => false,
    };
}

// How a value is picked while it is built: from which source, which of the source's values and
// for a seeded value the generator every part of it is drawn from.
const Pick = struct {
    // Where the value comes from. Never `factory`: a factory is called by `buildValue` directly.
    source: Source,

    // Which of the source's values, for the fixed lists.
    index: usize,

    // The generator, for a seeded value and null otherwise.
    random: ?std.Random,
};

// What a value factory's own parameters are built by: the first choice of each type.
fn Builder(comptime Locator: type) type {
    return struct {
        // The context of the call being built.
        ctx: Context(Locator),

        // Builds one parameter of a value factory into its slot. Into a slot rather than as a
        // return value because an error set cannot be the payload of an error union.
        pub fn fill(self: @This(), comptime Parameter: type, slot: *Parameter) anyerror!void {
            return buildValueInto(Parameter, Locator, self.ctx, .{ .source = .boundary, .index = 0 }, slot);
        }
    };
}

// What the run supplies for a supplied type.
fn supply(comptime T: type, ctx: anytype) T {
    if (T == std.mem.Allocator) {
        return ctx.call_allocator;
    }
    if (T == std.Io) {
        return ctx.io;
    }
    if (T == std.Random) {
        return ctx.random;
    }
    // The simulated current directory, which every relative path of the call starts from.
    if (T == std.Io.Dir) {
        return std.Io.Dir.cwd();
    }
    return ctx.writer;
}

// The one error handed to a parameter that takes an error set.
fn suppliedErrorOf(comptime E: type) E {
    if (@typeInfo(E).error_set) |errors| {
        return @field(E, errors[0].name);
    }
    return supplied_error;
}

// The pick for a part of a value, given the pick for the whole. A seeded value draws every part
// from the same generator. A fixed list steps each part through its own list in step with the
// whole's index, shifted by `shift` so the elements of an array differ from each other. A part the
// conditions say nothing about is left at its first boundary value.
fn pickForPart(comptime Part: type, comptime Locator: type, ctx: Context(Locator), pick: Pick, shift: usize, comptime depth: usize) anyerror!Pick {
    if (pick.random != null) {
        return pick;
    }
    const total = try countFrom(Part, Locator, ctx, pick.source, depth);
    if (total == 0) {
        return .{ .source = .boundary, .index = 0, .random = null };
    }
    return .{ .source = pick.source, .index = (pick.index + shift) % total, .random = null };
}

// Builds one value of `T` for the pick into a slot. Every part of a value is built this way because
// an error set cannot be the payload of an error union, so it cannot be returned from a function
// that can fail. An error set is given its first error.
fn buildInto(comptime T: type, comptime Locator: type, ctx: Context(Locator), pick: Pick, comptime depth: usize, slot: *T) anyerror!void {
    if (comptime @typeInfo(T) == .error_set) {
        slot.* = suppliedErrorOf(T);
        return;
    }
    slot.* = try buildFrom(T, Locator, ctx, pick, depth);
}

// Builds one value of `T` for the pick. Every choice is a pure function of the pick and the seed,
// so the same pick builds the same value and a failing call is reproduced by replaying it.
fn buildFrom(comptime T: type, comptime Locator: type, ctx: Context(Locator), pick: Pick, comptime depth: usize) anyerror!T {
    if (comptime @typeInfo(T) == .error_set) {
        @compileError("build: an error set is built with buildInto");
    }
    if (comptime isSupplied(T)) {
        return supply(T, ctx);
    }
    if (comptime isFactoryFirst(T, Locator)) {
        const total = comptime Locator.count(T);
        const index = if (pick.random) |random| random.uintLessThan(usize, total) else pick.index % total;
        return ctx.locator.make(T, index, Builder(Locator){ .ctx = ctx });
    }
    if (comptime T == std.Io.File) {
        if (pick.random) |random| {
            return boundaryFile(random.int(usize));
        }
        return boundaryFile(pick.index);
    }
    if (comptime depth == 0) {
        return error.ValueTooDeep;
    }
    if (comptime isOwnedList(T)) {
        const elements = try buildSlice(ElementsOf(T), Locator, ctx, pick, depth);
        var list: T = .empty;
        try list.appendSlice(ctx.call_allocator, elements);
        return list;
    }
    if (pick.source == .condition and comptime candidates.isCandidateType(T)) {
        const list = try candidates.candidatesFor(T, ctx.arena, ctx.conditions);
        if (list.len == 0) {
            return buildFrom(T, Locator, ctx, .{ .source = .boundary, .index = 0, .random = null }, depth);
        }
        return list[pick.index % list.len];
    }
    switch (@typeInfo(T)) {
        .void => {
            return {};
        },
        .bool => {
            if (pick.random) |random| {
                return random.boolean();
            }
            return pick.index % 2 == 1;
        },
        .int => {
            if (pick.random) |random| {
                return boundary.seededInteger(T, random);
            }
            const list = comptime boundary.boundaryIntegers(T);
            return list[pick.index % list.len];
        },
        .comptime_int, .comptime_float => {
            return 0;
        },
        .float => {
            if (pick.random) |random| {
                return boundary.seededFloat(T, random);
            }
            const list = comptime boundary.boundaryFloats(T);
            return list[pick.index % list.len];
        },
        .@"enum" => {
            const tags = comptime boundary.boundaryTags(T);
            if (pick.random) |random| {
                return tags[random.uintLessThan(usize, tags.len)];
            }
            return tags[pick.index % tags.len];
        },
        .optional => |info| {
            if (pick.random) |random| {
                if (random.boolean()) {
                    return null;
                }
                var inner: info.child = undefined;
                try buildInto(info.child, Locator, ctx, pick, depth - 1, &inner);
                // Said as the optional, because a bare error set value would be read as the error
                // the function returns.
                const wrapped: T = inner;
                return wrapped;
            }
            const inner = try countFrom(info.child, Locator, ctx, pick.source, depth - 1);
            const slot = pick.index % (1 + inner);
            if (slot == 0) {
                return null;
            }
            var held: info.child = undefined;
            try buildInto(info.child, Locator, ctx, .{ .source = pick.source, .index = slot - 1, .random = null }, depth - 1, &held);
            const wrapped: T = held;
            return wrapped;
        },
        .array => |info| {
            var made: T = undefined;
            for (&made, 0..) |*slot, position| {
                const part = try pickForPart(info.child, Locator, ctx, pick, position, depth - 1);
                try buildInto(info.child, Locator, ctx, part, depth - 1, slot);
            }
            return made;
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                return buildSlice(T, Locator, ctx, pick, depth);
            },
            .one => {
                const room = try ctx.arena.create(info.child);
                const part = try pickForPart(info.child, Locator, ctx, pick, 0, depth - 1);
                try buildInto(info.child, Locator, ctx, part, depth - 1, room);
                return room;
            },
            else => @compileError("build: unsupported pointer"),
        },
        .@"struct" => |info| {
            var made: T = undefined;
            inline for (info.fields) |field| {
                if (comptime field.is_comptime) {
                    continue;
                }
                if (comptime isBuiltField(field, Locator)) {
                    const part = try pickForPart(field.type, Locator, ctx, pick, 0, depth - 1);
                    try buildInto(field.type, Locator, ctx, part, depth - 1, &@field(made, field.name));
                } else {
                    @field(made, field.name) = comptime field.defaultValue().?;
                }
            }
            return made;
        },
        .@"union" => |info| {
            if (pick.random) |random| {
                const buildable = comptime blk: {
                    var total: usize = 0;
                    for (info.fields) |field| {
                        if (canMakeValue(field.type, Locator)) {
                            total += 1;
                        }
                    }
                    break :blk total;
                };
                const chosen = random.uintLessThan(usize, buildable);
                var seen: usize = 0;
                inline for (info.fields) |field| {
                    if (comptime canMakeValue(field.type, Locator)) {
                        if (seen == chosen) {
                            var held: field.type = undefined;
                            try buildInto(field.type, Locator, ctx, pick, depth - 1, &held);
                            return @unionInit(T, field.name, held);
                        }
                        seen += 1;
                    }
                }
                unreachable;
            }
            var offset: usize = 0;
            inline for (info.fields) |field| {
                if (comptime canMakeValue(field.type, Locator)) {
                    const total = try countFrom(field.type, Locator, ctx, pick.source, depth - 1);
                    if (pick.index >= offset and pick.index < offset + total) {
                        const part: Pick = .{ .source = pick.source, .index = pick.index - offset, .random = null };
                        var held: field.type = undefined;
                        try buildInto(field.type, Locator, ctx, part, depth - 1, &held);
                        return @unionInit(T, field.name, held);
                    }
                    offset += total;
                }
            }
            if (pick.source != .boundary) {
                return buildFrom(T, Locator, ctx, .{ .source = .boundary, .index = 0, .random = null }, depth);
            }
            return buildFrom(T, Locator, ctx, .{ .source = .boundary, .index = pick.index % offset, .random = null }, depth);
        },
        else => @compileError("build: unsupported type " ++ @typeName(T)),
    }
}

// A slice of whatever the element type is. A constant byte slice is a string: one of the boundary
// strings, or random text. Any other slice has a length from the fixed list or from the generator
// and its elements are built one by one.
//
// A slice the callee can write into is always freshly allocated. A boundary string is a literal in
// read-only memory, so handing one to a function that writes through it would fault on the write
// rather than say anything about the code.
fn buildSlice(comptime T: type, comptime Locator: type, ctx: Context(Locator), pick: Pick, comptime depth: usize) anyerror!T {
    const info = @typeInfo(T).pointer;
    const Child = info.child;
    if (comptime Child == u8 and info.is_const) {
        const text: []const u8 = if (pick.random) |random|
            try boundary.seededText(ctx.arena, random)
        else
            boundary.boundary_strings[pick.index % boundary.boundary_strings.len];
        // A string and a string with a sentinel are two types: the sentinel is part of the type,
        // not a property of the bytes. A parameter asking for one gets a copy that carries it.
        if (comptime info.sentinel() == null) {
            return text;
        }
        const room = try roomFor(T, ctx.arena, text.len);
        @memcpy(room, text);
        return room;
    }
    const length = if (pick.random) |random| boundary.seededLength(random) else sliceBoundaryLength(pick.index);
    const room = try roomFor(T, ctx.arena, length);
    // Every element is built the same way (a seeded slice draws each from the generator and any
    // other from its type's first boundary value), so the choice's index decides the length and
    // nothing else about the slice.
    const part: Pick = if (pick.random != null) pick else .{ .source = .boundary, .index = 0, .random = null };
    for (room) |*slot| {
        try buildInto(Child, Locator, ctx, part, depth - 1, slot);
    }
    return room;
}

// What `roomFor` returns: a mutable slice that carries the sentinel the slice type has, if any. A
// mutable slice passes where a constant one is asked for and the sentinel rides along.
fn RoomFor(comptime T: type) type {
    const info = @typeInfo(T).pointer;
    if (comptime info.sentinel()) |end| {
        return [:end]info.child;
    }
    return []info.child;
}

// Room for a slice of `T`, allocated with T's own sentinel where it has one.
fn roomFor(comptime T: type, arena: std.mem.Allocator, length: usize) error{OutOfMemory}!RoomFor(T) {
    const info = @typeInfo(T).pointer;
    if (comptime info.sentinel()) |end| {
        return arena.allocSentinel(info.child, length, end);
    }
    return arena.alloc(info.child, length);
}

// Builds the value for one choice. A factory choice calls the factory at that index in the sim
// file's declaration order. The other choices build the value from its type: a boundary choice
// takes the boundary list at that index, a seeded choice draws from a generator started from the
// run's seed, the parameter's position and the index and a condition choice takes the candidate
// at that index. The same choice and seed always build the same value.
pub fn buildValue(comptime T: type, comptime Locator: type, ctx: Context(Locator), choice: Choice) anyerror!T {
    if (comptime @typeInfo(T) == .error_set) {
        @compileError("buildValue cannot return an error set: use buildValueInto");
    }
    switch (choice.source) {
        .factory => {
            if (comptime !Locator.canMake(T)) {
                return error.NoValueFactory;
            }
            return ctx.locator.make(T, choice.index, Builder(Locator){ .ctx = ctx });
        },
        .boundary, .condition => {
            return buildFrom(T, Locator, ctx, .{ .source = choice.source, .index = choice.index, .random = null }, value_depth_limit);
        },
        .seeded => {
            var prng = std.Random.DefaultPrng.init(boundary.mixSeed(ctx.seed, ctx.position, choice.index));
            return buildFrom(T, Locator, ctx, .{ .source = .seeded, .index = choice.index, .random = prng.random() }, value_depth_limit);
        },
    }
}

// Builds the value for one choice into a slot. The same as `buildValue` and the only way to build
// an error set, which is given the error a value factory returns for a factory choice and its first
// error (or the supplied error for `anyerror`) for any other.
pub fn buildValueInto(comptime T: type, comptime Locator: type, ctx: Context(Locator), choice: Choice, slot: *T) anyerror!void {
    if (comptime @typeInfo(T) == .error_set) {
        if (comptime Locator.canMake(T)) {
            if (choice.source == .factory) {
                try ctx.locator.makeInto(T, choice.index, Builder(Locator){ .ctx = ctx }, slot);
                return;
            }
        }
        slot.* = suppliedErrorOf(T);
        return;
    }
    slot.* = try buildValue(T, Locator, ctx, choice);
}

// Whether two values of a type can be compared here, which is what lets a list of choices drop
// the ones that build a value an earlier choice already built.
fn isComparable(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => true,
        .optional => |info| isComparable(info.child),
        .pointer => |info| info.size == .slice and info.child == u8,
        else => false,
    };
}

// Whether two values of a comparable type are equal. Two not-a-number floats are equal, so a list
// holds one of them.
fn isSameValue(comptime T: type, first: T, second: T) bool {
    return switch (@typeInfo(T)) {
        .float => first == second or (std.math.isNan(first) and std.math.isNan(second)),
        .optional => |info| blk: {
            if (first == null or second == null) {
                break :blk first == null and second == null;
            }
            break :blk isSameValue(info.child, first.?, second.?);
        },
        .pointer => std.mem.eql(u8, first, second),
        else => first == second,
    };
}

// Adds a choice to the list, unless the type's values can be compared and the choice builds one an
// earlier choice already built.
fn appendDistinct(
    comptime T: type,
    comptime Locator: type,
    ctx: Context(Locator),
    list: *std.ArrayList(Choice),
    kept: *std.ArrayList(T),
    choice: Choice,
) anyerror!void {
    if (comptime isComparable(T)) {
        const value = try buildValue(T, Locator, ctx, choice);
        for (kept.items) |earlier| {
            if (isSameValue(T, earlier, value)) {
                return;
            }
        }
        try kept.append(ctx.arena, value);
    }
    try list.append(ctx.arena, choice);
}

// Lists the choices available for a parameter of type `T`, first the baseline. For a type a value
// factory builds, the choices are the factories in the order the sim file declares them, so the
// first factory written is the baseline: write the working one first. For any other type they are
// the boundary values, then the few seeded values, then the values from the conditions, then the
// factories (if a sim file has any that return the type), with a choice dropped when it builds a
// value an earlier one built. A type that cannot be built has none. A type the run supplies has
// one. `ctx.position`, `ctx.seed` and `ctx.conditions` decide the values; the list is allocated
// from `ctx.arena`.
pub fn listChoices(comptime T: type, comptime Locator: type, ctx: Context(Locator)) anyerror![]const Choice {
    var list: std.ArrayList(Choice) = .empty;
    if (comptime isSupplied(T)) {
        try list.append(ctx.arena, .{ .source = .boundary, .index = 0 });
        return list.items;
    }
    if (comptime isFactoryFirst(T, Locator)) {
        try appendFactoryChoices(T, Locator, ctx, &list);
        return list.items;
    }
    if (comptime !canMakeValue(T, Locator)) {
        return list.items;
    }

    var kept: std.ArrayList(T) = .empty;
    const fixed = comptime boundaryCount(T, Locator, value_depth_limit);
    for (0..fixed) |index| {
        try appendDistinct(T, Locator, ctx, &list, &kept, .{ .source = .boundary, .index = @intCast(index) });
    }
    if (comptime isSeedVarying(T, Locator, value_depth_limit)) {
        for (0..boundary.seeded_count) |index| {
            try appendDistinct(T, Locator, ctx, &list, &kept, .{ .source = .seeded, .index = @intCast(index) });
        }
    }
    const read = try conditionCount(T, Locator, ctx, value_depth_limit);
    for (0..read) |index| {
        try appendDistinct(T, Locator, ctx, &list, &kept, .{ .source = .condition, .index = @intCast(index) });
    }
    try appendFactoryChoices(T, Locator, ctx, &list);
    return list.items;
}

// Adds one choice for each value factory of `T`.
fn appendFactoryChoices(comptime T: type, comptime Locator: type, ctx: Context(Locator), list: *std.ArrayList(Choice)) anyerror!void {
    if (comptime Locator.canMake(T)) {
        for (0..Locator.count(T)) |index| {
            try list.append(ctx.arena, .{ .source = .factory, .index = @intCast(index) });
        }
    }
}

// Lists the choices for every parameter of a function, in parameter order.
pub fn listParameterChoices(comptime Function: type, comptime Locator: type, ctx: Context(Locator)) anyerror![]const []const Choice {
    const params = @typeInfo(Function).@"fn".params;
    const lists = try ctx.arena.alloc([]const Choice, params.len);
    inline for (params, 0..) |param, position| {
        var local = ctx;
        local.position = @intCast(position);
        lists[position] = try listChoices(param.type.?, Locator, local);
    }
    return lists;
}

// The finite list of call specifications for a function: the baseline, then every other choice of
// each parameter in turn with the others at their baseline, then a bounded set of combinations
// across parameters (see `call_specs.zig` for the bound). The list is the same every time for the
// same seed, conditions and sim file and is empty when some parameter has no value to give.
pub fn listCallSpecs(comptime Function: type, comptime Locator: type, ctx: Context(Locator)) anyerror![]const Spec {
    const lists = try listParameterChoices(Function, Locator, ctx);
    return call_specs.generateSpecs(ctx.arena, lists);
}

// Builds the real argument tuple for a function from a specification, one choice per parameter.
// A specification of the wrong length is an error.
pub fn buildArguments(comptime Function: type, comptime Locator: type, ctx: Context(Locator), spec: Spec) anyerror!std.meta.ArgsTuple(Function) {
    const params = @typeInfo(Function).@"fn".params;
    if (spec.len != params.len) {
        return error.WrongSpecLength;
    }
    var args: std.meta.ArgsTuple(Function) = undefined;
    inline for (&args, 0..) |*slot, position| {
        var local = ctx;
        local.position = @intCast(position);
        try buildValueInto(@TypeOf(slot.*), Locator, local, spec[position], slot);
    }
    return args;
}

// Whether a function can be called from its signature alone. A generic one cannot: `anytype` and a
// `comptime` type parameter have no value a signature decides, so something has to supply it and
// nothing here can. Generic functions are reported as ones Faultline could not call.
pub fn canExercise(comptime Function: type, comptime Locator: type) bool {
    const info = @typeInfo(Function);
    if (info != .@"fn") {
        return false;
    }
    if (info.@"fn".is_generic or info.@"fn".is_var_args) {
        return false;
    }
    inline for (info.@"fn".params) |param| {
        const T = param.type orelse return false;
        if (!canMakeValue(T, Locator)) {
            return false;
        }
    }
    return true;
}

// Which parameter stops a function being callable from its signature alone, named so a run can ask
// for a value factory rather than leaving the function silently unexercised. Null when every
// parameter can be built and null for a generic function, whose problem is not a missing factory.
pub fn firstUnbuildableParameter(comptime Function: type, comptime Locator: type) ?type {
    const info = @typeInfo(Function);
    if (info != .@"fn") {
        return null;
    }
    if (info.@"fn".is_generic or info.@"fn".is_var_args) {
        return null;
    }
    inline for (info.@"fn".params) |param| {
        const T = param.type orelse return null;
        if (!canMakeValue(T, Locator)) {
            return T;
        }
    }
    return null;
}

// One call with the arguments a specification names. The error the function returns, if it
// returns one, is not an error of the call: what the run learns comes from where the call went.
// An error building the arguments is returned.
pub fn callOnce(comptime function: anytype, comptime Locator: type, ctx: Context(Locator), spec: Spec) anyerror!void {
    const Function = @TypeOf(function);
    const args = try buildArguments(Function, Locator, ctx, spec);
    const Return = @typeInfo(Function).@"fn".return_type.?;
    if (comptime @typeInfo(Return) == .error_union) {
        _ = @call(.auto, function, args) catch {};
    } else {
        _ = @call(.auto, function, args);
    }
}

test {
    _ = @import("auto.test.zig");
}
