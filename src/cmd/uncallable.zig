// Finds the functions Faultline cannot call and says what stopped each one. A function that is
// generic over a type is called by instantiating it with a stand-in type. That works until the body
// looks inside the type (its declarations, its fields, its enum values), or another parameter is
// written in terms of the type parameter, because no stand-in satisfies either and the compiler
// refuses the whole program rather than the one call. These functions are left out of the calls and
// reported, so a person can see why and write a scenario for each.
//
// Read from the tokens, because a signature does not carry it: `comptime T: type` looks the same
// whether the body returns a `T` or reads `T`'s declarations.

const std = @import("std");

// What stopped a function being called.
pub const Reason = enum {
    // The body asks the type parameter for something of its own, such as its declarations, its
    // fields or its enum values, or hands the parameter to something that does.
    reflects_on_type,

    // Another parameter is written in terms of the type parameter, as `[]const T` or `?T` is, so no
    // value for it can be built until the type is known.
    parameter_uses_type,

    // A sentence saying what stopped the function, for the report.
    pub fn sentence(reason: Reason) []const u8 {
        return switch (reason) {
            .reflects_on_type => "The function looks inside a type it is given and no stand-in type has anything to look at.",
            .parameter_uses_type => "A parameter is written in terms of a type parameter, so no value for it can be built before the type is known.",
        };
    }
};

// A function that could not be called.
pub const Uncallable = struct {
    // The function's name. A slice of the source that was read.
    name: []const u8,

    // What stopped it.
    reason: Reason,

    // The line the function is declared on, counting from one.
    line: u32,
};

// Every function in `source` that could not be called, in the order declared, one entry per
// declaration. A function that both looks inside the type and uses it in a parameter is reported for
// the first. The names point into `source`, which has to outlive the result; the caller owns the
// list.
pub fn uncallableFunctionsIn(allocator: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error![]Uncallable {
    var tokens: std.ArrayList(std.zig.Token) = .empty;
    defer tokens.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .eof) {
            break;
        }
    }

    var functions = try readFunctions(allocator, source, tokens.items);
    defer freeFunctions(allocator, &functions);

    settleReflection(functions.items);

    var found: std.ArrayList(Uncallable) = .empty;
    errdefer found.deinit(allocator);
    for (functions.items) |function| {
        var reflects = false;
        var uses = false;
        for (function.parameters.items) |parameter| {
            if (parameter.is_a_type and parameter.reflected) {
                reflects = true;
            }
            if (parameter.uses_a_type_parameter) {
                uses = true;
            }
        }
        if (reflects) {
            try found.append(allocator, .{ .name = function.name, .reason = .reflects_on_type, .line = function.line });
        } else if (uses) {
            try found.append(allocator, .{ .name = function.name, .reason = .parameter_uses_type, .line = function.line });
        }
    }
    return found.toOwnedSlice(allocator);
}

// One parameter of one function, as the walk needs it: its name, whether it is a `comptime` type,
// and whether anything the function does with it needs a real type rather than a stand-in.
const Parameter = struct {
    // The parameter's name, a slice of the source.
    name: []const u8,

    // Whether it is written `comptime name: type`.
    is_a_type: bool,

    // Whether something the function does with it needs a real type.
    reflected: bool = false,

    // Whether the type is written as one of the function's own `comptime` type parameters, as
    // `[]const T` or `?T` or `T` itself is. `@typeInfo` reports such a parameter and an `anytype`
    // identically, as a parameter with no type at all, so a run that went by the types alone would
    // hand the stand-in it makes for an `anytype` to a `[]const T` and the compiler would refuse the
    // run's own binary. The source is the only place the difference is written down.
    uses_a_type_parameter: bool = false,
};

// One parameter of this function handed to another function, at the position that other function
// takes it. Following these is what tells a parameter passed straight through from one reflected on.
const Handover = struct {
    // The index of the parameter that is passed on.
    parameter: usize,

    // The name of the function it is passed to.
    callee: []const u8,

    // The position it is passed at.
    argument: usize,
};

// One function with type parameters: what it takes and what it does with them.
const Function = struct {
    // The function's name, a slice of the source.
    name: []const u8,

    // The line the function is declared on, counting from one.
    line: u32,

    // Every parameter, in order.
    parameters: std.ArrayList(Parameter),

    // Every place a type parameter is passed to another function.
    handovers: std.ArrayList(Handover),
};

fn freeFunctions(allocator: std.mem.Allocator, functions: *std.ArrayList(Function)) void {
    for (functions.items) |*function| {
        function.parameters.deinit(allocator);
        function.handovers.deinit(allocator);
    }
    functions.deinit(allocator);
}

// Whether the type written from `at` onwards names one of the type parameters declared before it.
// The type runs to the comma that ends this parameter or to the end of the list, whichever comes
// first and brackets and parentheses inside it are counted so a nested comma does not end it early.
//
// `anytype` names nothing, which is the case this is here to tell apart from the rest.
fn namesATypeParameter(
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    at: usize,
    declared: []const Parameter,
) bool {
    var depth: usize = 0;
    var scan = at;
    while (scan < tokens.len) : (scan += 1) {
        switch (tokens[scan].tag) {
            .l_paren, .l_bracket, .l_brace => {
                depth += 1;
            },
            .r_paren, .r_bracket, .r_brace => {
                if (depth == 0) {
                    return false;
                }
                depth -= 1;
            },
            .comma => {
                if (depth == 0) {
                    return false;
                }
            },
            .identifier => {
                for (declared) |parameter| {
                    if (parameter.is_a_type and std.mem.eql(u8, parameter.name, textOf(source, tokens[scan]))) {
                        return true;
                    }
                }
            },
            else => {},
        }
    }
    return false;
}

// Every function the file declares, with its parameters and what it does with them. Names point
// into `source`, which the caller holds for as long as the result is used.
fn readFunctions(allocator: std.mem.Allocator, source: [:0]const u8, tokens: []const std.zig.Token) !std.ArrayList(Function) {
    var functions: std.ArrayList(Function) = .empty;
    errdefer freeFunctions(allocator, &functions);

    var at: usize = 0;
    while (at < tokens.len) : (at += 1) {
        if (tokens[at].tag != .keyword_fn) {
            continue;
        }
        // A function type rather than a declaration: no name and nothing exercises it.
        if (at + 2 >= tokens.len or tokens[at + 1].tag != .identifier or tokens[at + 2].tag != .l_paren) {
            continue;
        }

        var function: Function = .{
            .name = textOf(source, tokens[at + 1]),
            .line = lineAt(source, tokens[at + 1].loc.start),
            .parameters = .empty,
            .handovers = .empty,
        };
        errdefer {
            function.parameters.deinit(allocator);
            function.handovers.deinit(allocator);
        }

        var after = at + 3;
        var parens: usize = 1;
        var comptime_next = false;
        while (after < tokens.len and parens > 0) : (after += 1) {
            switch (tokens[after].tag) {
                .l_paren => parens += 1,
                .r_paren => parens -= 1,
                .keyword_comptime => comptime_next = true,
                .identifier => {
                    // A parameter is `<name>:` at the top level of the list. Anything else here is
                    // part of a type, which the name before it already accounted for.
                    if (parens == 1 and after + 1 < tokens.len and tokens[after + 1].tag == .colon) {
                        const named_a_type = comptime_next and after + 2 < tokens.len and
                            tokens[after + 2].tag == .identifier and
                            std.mem.eql(u8, textOf(source, tokens[after + 2]), "type");
                        try function.parameters.append(allocator, .{
                            .name = textOf(source, tokens[after]),
                            .is_a_type = named_a_type,
                            .uses_a_type_parameter = namesATypeParameter(source, tokens, after + 2, function.parameters.items),
                        });
                        comptime_next = false;
                    }
                },
                .comma => comptime_next = false,
                else => {},
            }
        }

        // Back to just past the name, so a function declared inside this one's body is read too.
        at += 1;

        var holds_a_type = false;
        for (function.parameters.items) |parameter| {
            if (parameter.is_a_type) {
                holds_a_type = true;
            }
        }
        if (!holds_a_type) {
            function.parameters.deinit(allocator);
            function.handovers.deinit(allocator);
            continue;
        }

        // From the end of the parameter list to the end of the body, which takes in the return
        // type: `failuresFrom` reflects on its parameter there and nowhere else.
        try readUses(allocator, source, tokens, after, &function);
        try functions.append(allocator, function);
    }

    return functions;
}

// What one function does with its type parameters, from the end of its parameter list to the end of
// its body.
fn readUses(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    tokens: []const std.zig.Token,
    from: usize,
    function: *Function,
) !void {
    // One entry per open parenthesis. A parenthesis that only groups an expression has no callee.
    const Call = struct {
        callee: ?[]const u8,
        builtin: bool,
        any_type: bool,
        argument: usize,
    };
    var calls: std.ArrayList(Call) = .empty;
    defer calls.deinit(allocator);

    var braces: usize = 0;
    var body_started = false;
    var at = from;
    while (at < tokens.len) : (at += 1) {
        switch (tokens[at].tag) {
            .eof => return,
            .l_brace => {
                braces += 1;
                body_started = true;
            },
            .r_brace => {
                if (braces == 0) {
                    return;
                }
                braces -= 1;
                if (body_started and braces == 0) {
                    return;
                }
            },
            .semicolon => {
                // A declaration with no body: there is nothing to read.
                if (!body_started) {
                    return;
                }
            },
            .comma => {
                if (calls.items.len > 0) {
                    calls.items[calls.items.len - 1].argument += 1;
                }
            },
            .l_paren => {
                const before = tokens[at - 1];
                const calling = before.tag == .identifier or before.tag == .builtin;
                try calls.append(allocator, .{
                    .callee = if (calling) textOf(source, before) else null,
                    .builtin = before.tag == .builtin,
                    .any_type = before.tag == .builtin and worksForAnyType(textOf(source, before)),
                    .argument = 0,
                });
            },
            .r_paren => {
                if (calls.items.len > 0) {
                    _ = calls.pop();
                }
            },
            .identifier => {
                const index = parameterNamed(function.*, textOf(source, tokens[at])) orelse continue;
                if (!function.parameters.items[index].is_a_type) {
                    continue;
                }
                // Asked for something of its own: only a real type has declarations.
                if (at + 1 < tokens.len and tokens[at + 1].tag == .period) {
                    function.parameters.items[index].reflected = true;
                    continue;
                }
                if (calls.items.len == 0) {
                    continue;
                }
                const call = calls.items[calls.items.len - 1];
                if (call.callee == null or call.any_type) {
                    continue;
                }
                if (call.builtin) {
                    function.parameters.items[index].reflected = true;
                    continue;
                }
                // An ordinary call: whether this matters depends on what that function does with
                // the argument, which is settled once every function has been read.
                try function.handovers.append(allocator, .{
                    .parameter = index,
                    .callee = call.callee.?,
                    .argument = call.argument,
                });
            },
            else => {},
        }
    }
}

fn parameterNamed(function: Function, name: []const u8) ?usize {
    for (function.parameters.items, 0..) |parameter, index| {
        if (std.mem.eql(u8, parameter.name, name)) {
            return index;
        }
    }
    return null;
}

// Follows every handover until nothing changes. A parameter passed to a function this file does not
// declare is counted as reflected on, because there is no way to see what happens to it there.
fn settleReflection(functions: []Function) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (functions) |function| {
            for (function.handovers.items) |handover| {
                if (function.parameters.items[handover.parameter].reflected) {
                    continue;
                }
                var reflected = true;
                for (functions) |*called| {
                    if (!std.mem.eql(u8, called.name, handover.callee)) {
                        continue;
                    }
                    reflected = handover.argument < called.parameters.items.len and
                        called.parameters.items[handover.argument].reflected;
                }
                if (reflected) {
                    function.parameters.items[handover.parameter].reflected = true;
                    changed = true;
                }
            }
        }
    }
}

// The builtins that take a type and work whatever it is, so handing one a stand-in says nothing
// about whether the function can be exercised.
fn worksForAnyType(name: []const u8) bool {
    for ([_][]const u8{ "@as", "@sizeOf", "@alignOf", "@typeName" }) |builtin| {
        if (std.mem.eql(u8, name, builtin)) {
            return true;
        }
    }
    return false;
}

// The line a byte offset is on, counting from one.
fn lineAt(source: []const u8, offset: usize) u32 {
    var line: u32 = 1;
    for (source[0..offset]) |byte| {
        if (byte == '\n') {
            line += 1;
        }
    }
    return line;
}

fn textOf(source: [:0]const u8, token: std.zig.Token) []const u8 {
    return source[token.loc.start..token.loc.end];
}

test {
    _ = @import("uncallable.test.zig");
}
