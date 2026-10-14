// Finds what a `.sim.zig` file offers by the signature of each public function: value factories,
// scenarios and expectation functions. There are no annotations and no registration list, so a
// function is picked up by being written with the right signature.
//
// The sim file is read with `std.zig.Ast`. Only the text of the file is needed, so a finder never
// compiles anything.

const std = @import("std");
const Ast = std.zig.Ast;

// The ending of a sim file's name, which is also what is replaced to find the source file beside it.
pub const sim_suffix = ".sim.zig";

// The ending of a source file's name.
pub const source_suffix = ".zig";

// The name a context type has to end in for a function to be a scenario.
pub const scenario_context = "ScenarioContext";

// The name a context type has to end in for a function to be an expectation function.
pub const expectation_context = "ExpectationContext";

// Why a sim file could not be read.
pub const FindError = error{
    // The source does not parse as Zig.
    SourceDoesNotParse,

    // The path does not end in `.sim.zig`, so there is no source file beside it to name.
    NotASimFile,
} || std.mem.Allocator.Error;

// A public function that builds a value of one of the project's own types.
pub const ValueFactory = struct {
    // The function's name.
    name: []const u8,

    // The return type as written, including any `!` or `?`. A slice of the sim file's text.
    return_type: []const u8,

    // The type of the value built, with any error set and `?` taken off. A slice of the sim file's
    // text.
    value_type: []const u8,

    // The public struct the function is a method of, for a struct factory that keeps state between
    // calls. Null for a function declared at the top of the file. A slice of the sim file's text.
    struct_name: ?[]const u8,

    // The type text of each parameter the caller has to supply, in order, as written. A struct
    // factory's `self` is not listed. A parameter with no written type is `anytype`. Slices of the
    // sim file's text, in a list owned by the findings.
    parameters: []const []const u8,

    // The line the function is declared on, counting from one.
    line: u32,
};

// A function written as `pub fn name(context: *sim.ScenarioContext) anyerror!void`.
pub const Scenario = struct {
    // The function's name. A slice of the sim file's text.
    name: []const u8,

    // The line the function is declared on, counting from one.
    line: u32,
};

// A function written as `pub fn name(context: *sim.ExpectationContext) anyerror!void`.
pub const Expectation = struct {
    // The function's name. A slice of the sim file's text.
    name: []const u8,

    // The line the function is declared on, counting from one.
    line: u32,

    // The source file the function checks, found by dropping `.sim` from the sim file's path. The
    // expectation runs after every call of a function in this file and after every scenario in the
    // sim file. Owned by the findings.
    source_file: []const u8,
};

// Everything one sim file offers. Names are slices of the text that was read, which has to outlive
// the findings.
pub const Findings = struct {
    // The value factories, in the order they are declared.
    factories: []ValueFactory,

    // The scenarios, in the order they are declared.
    scenarios: []Scenario,

    // The expectation functions, in the order they are declared.
    expectations: []Expectation,

    // Releases the lists.
    pub fn deinit(findings: Findings, allocator: std.mem.Allocator) void {
        for (findings.factories) |factory| {
            allocator.free(factory.parameters);
        }
        allocator.free(findings.factories);
        allocator.free(findings.scenarios);
        for (findings.expectations) |expectation| {
            allocator.free(expectation.source_file);
        }
        allocator.free(findings.expectations);
    }
};

// The path of the source file beside a sim file: `src/git.sim.zig` gives `src/git.zig`. The caller
// owns what comes back.
pub fn sourcePathOf(allocator: std.mem.Allocator, sim_path: []const u8) FindError![]u8 {
    if (!std.mem.endsWith(u8, sim_path, sim_suffix) or sim_path.len == sim_suffix.len) {
        return error.NotASimFile;
    }
    const stem = sim_path[0 .. sim_path.len - sim_suffix.len];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, source_suffix });
}

// Reads the factories, scenarios and expectation functions out of one sim file's text. `sim_path` is
// the file's path relative to the project root, used to name the source file beside it.
pub fn findIn(allocator: std.mem.Allocator, source: [:0]const u8, sim_path: []const u8) FindError!Findings {
    const source_path = try sourcePathOf(allocator, sim_path);
    defer allocator.free(source_path);

    var tree = Ast.parse(allocator, source, .zig) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return error.SourceDoesNotParse;
    }

    var factories: std.ArrayList(ValueFactory) = .empty;
    errdefer {
        for (factories.items) |factory| {
            allocator.free(factory.parameters);
        }
        factories.deinit(allocator);
    }
    var scenarios: std.ArrayList(Scenario) = .empty;
    errdefer scenarios.deinit(allocator);
    var expectations: std.ArrayList(Expectation) = .empty;
    errdefer {
        for (expectations.items) |expectation| {
            allocator.free(expectation.source_file);
        }
        expectations.deinit(allocator);
    }

    for (tree.rootDecls()) |node| {
        switch (tree.nodeTag(node)) {
            .fn_decl => {
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, node) orelse continue;
                if (proto.visib_token == null) {
                    continue;
                }
                const name = tree.tokenSlice(proto.name_token orelse continue);
                const line = lineOf(tree, proto.ast.fn_token);

                if (isContextFunction(tree, proto, scenario_context)) {
                    try scenarios.append(allocator, .{ .name = name, .line = line });
                } else if (isContextFunction(tree, proto, expectation_context)) {
                    const owned = try allocator.dupe(u8, source_path);
                    errdefer allocator.free(owned);
                    try expectations.append(allocator, .{ .name = name, .line = line, .source_file = owned });
                } else if (try readFactory(allocator, tree, proto, name, line, null)) |factory| {
                    errdefer allocator.free(factory.parameters);
                    try factories.append(allocator, factory);
                }
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                try readStruct(allocator, tree, node, &factories);
            },
            else => {},
        }
    }

    const factory_slice = try factories.toOwnedSlice(allocator);
    errdefer allocator.free(factory_slice);
    const scenario_slice = try scenarios.toOwnedSlice(allocator);
    errdefer allocator.free(scenario_slice);
    const expectation_slice = try expectations.toOwnedSlice(allocator);
    return .{ .factories = factory_slice, .scenarios = scenario_slice, .expectations = expectation_slice };
}

// Adds the struct factories of one top-level declaration, when it is `pub const Name = struct {...}`.
fn readStruct(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, factories: *std.ArrayList(ValueFactory)) std.mem.Allocator.Error!void {
    const declaration = tree.fullVarDecl(node) orelse return;
    if (declaration.visib_token == null) {
        return;
    }
    if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token), "const")) {
        return;
    }
    const init_node = declaration.ast.init_node.unwrap() orelse return;
    var container_buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&container_buffer, init_node) orelse return;
    if (!std.mem.eql(u8, tree.tokenSlice(container.ast.main_token), "struct")) {
        return;
    }
    const struct_name = tree.tokenSlice(declaration.ast.mut_token + 1);

    for (container.ast.members) |member| {
        if (tree.nodeTag(member) != .fn_decl) {
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, member) orelse continue;
        if (proto.visib_token == null) {
            continue;
        }
        const name = tree.tokenSlice(proto.name_token orelse continue);
        if (!hasSelfParameter(tree, proto, struct_name)) {
            continue;
        }
        if (try readFactory(allocator, tree, proto, name, lineOf(tree, proto.ast.fn_token), struct_name)) |factory| {
            errdefer allocator.free(factory.parameters);
            try factories.append(allocator, factory);
        }
    }
}

// Whether a function's first parameter is the struct it is declared in, by pointer or by value,
// written as the struct's name or as `Self`. Further parameters are allowed.
fn hasSelfParameter(tree: Ast, proto: Ast.full.FnProto, struct_name: []const u8) bool {
    if (proto.ast.params.len == 0) {
        return false;
    }
    var text = std.mem.trim(u8, tree.getNodeSource(proto.ast.params[0]), " ");
    if (std.mem.startsWith(u8, text, "*")) {
        text = text[1..];
    }
    if (std.mem.startsWith(u8, text, "const ")) {
        text = text[6..];
    }
    return std.mem.eql(u8, text, struct_name) or std.mem.eql(u8, text, "Self");
}

// The value factory a function is, or null when its return type is not a value of the project's own
// type. `struct_name` is the struct the function is a method of.
fn readFactory(allocator: std.mem.Allocator, tree: Ast, proto: Ast.full.FnProto, name: []const u8, line: u32, struct_name: ?[]const u8) std.mem.Allocator.Error!?ValueFactory {
    const return_node = proto.ast.return_type.unwrap() orelse return null;
    const written = std.mem.trim(u8, tree.getNodeSource(return_node), " ");
    const return_type = withBang(tree, return_node, written);
    const value_type = valueTypeOf(return_type);
    if (!isOwnTypeName(value_type)) {
        return null;
    }

    // A struct factory's first parameter is `self`, which the caller already holds.
    var parameters: std.ArrayList([]const u8) = .empty;
    errdefer parameters.deinit(allocator);
    var iterator = proto.iterate(&tree);
    var is_first = true;
    while (iterator.next()) |parameter| {
        if (is_first and struct_name != null) {
            is_first = false;
            continue;
        }
        is_first = false;
        const type_text = if (parameter.type_expr) |type_node| tree.getNodeSource(type_node) else "anytype";
        try parameters.append(allocator, std.mem.trim(u8, type_text, " "));
    }

    return .{
        .name = name,
        .return_type = return_type,
        .value_type = value_type,
        .struct_name = struct_name,
        .parameters = try parameters.toOwnedSlice(allocator),
        .line = line,
    };
}

// The return type text with the `!` of an inferred error set put back on the front. The parser keeps
// that `!` outside the node, so the node's own text starts after it.
fn withBang(tree: Ast, return_node: Ast.Node.Index, written: []const u8) []const u8 {
    const first = tree.firstToken(return_node);
    if (first > 0 and tree.tokenTag(first - 1) == .bang) {
        const start = tree.tokenStart(first - 1);
        return tree.source[start .. start + 1 + written.len];
    }
    return written;
}

// The type that is built once the error set and the `?` are taken off a return type.
fn valueTypeOf(return_type: []const u8) []const u8 {
    var text = return_type;
    if (std.mem.lastIndexOfScalar(u8, text, '!')) |bang| {
        text = text[bang + 1 ..];
    }
    while (text.len > 0 and text[0] == '?') {
        text = text[1..];
    }
    return std.mem.trim(u8, text, " ");
}

// Names that are types of the language itself, so a function returning one is not building a value of
// the project's own.
const language_type_names = [_][]const u8{
    "void",
    "bool",
    "type",
    "anytype",
    "anyerror",
    "noreturn",
    "anyopaque",
    "usize",
    "isize",
    "comptime_int",
    "comptime_float",
    "c_int",
    "c_uint",
    "c_long",
    "c_ulong",
    "c_char",
    "c_short",
    "c_ushort",
    "c_longlong",
    "c_ulonglong",
    "f16",
    "f32",
    "f64",
    "f80",
    "f128",
};

// Whether a type, as written, names one of the project's own types: a plain name, or a name reached
// through modules (`models.Item`) and neither a type of the language nor of `std`. Slices, pointers
// and generic types are not plain names and are not taken.
fn isOwnTypeName(text: []const u8) bool {
    if (text.len == 0) {
        return false;
    }
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '.') {
            return false;
        }
    }
    if (std.mem.startsWith(u8, text, "std.")) {
        return false;
    }
    for (language_type_names) |name| {
        if (std.mem.eql(u8, text, name)) {
            return false;
        }
    }
    if (text.len > 1 and (text[0] == 'u' or text[0] == 'i') and isAllDigits(text[1..])) {
        return false;
    }
    return true;
}

// Whether every byte is a decimal digit.
fn isAllDigits(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return false;
        }
    }
    return true;
}

// Whether a function is `fn (*<anything>.<context_name>) anyerror!void`: one parameter that points to
// a type named `context_name`, however it is spelled and the return type `anyerror!void`.
fn isContextFunction(tree: Ast, proto: Ast.full.FnProto, context_name: []const u8) bool {
    if (proto.ast.params.len != 1) {
        return false;
    }
    const return_node = proto.ast.return_type.unwrap() orelse return false;
    const return_text = withBang(tree, return_node, std.mem.trim(u8, tree.getNodeSource(return_node), " "));
    if (!std.mem.eql(u8, return_text, "anyerror!void")) {
        return false;
    }

    const parameter = std.mem.trim(u8, tree.getNodeSource(proto.ast.params[0]), " ");
    if (parameter.len < 2 or parameter[0] != '*') {
        return false;
    }
    const pointee = parameter[1..];
    if (!std.mem.endsWith(u8, pointee, context_name)) {
        return false;
    }
    const before = pointee[0 .. pointee.len - context_name.len];
    return before.len == 0 or before[before.len - 1] == '.';
}

// The line a token is on, counting from one.
fn lineOf(tree: Ast, token: Ast.TokenIndex) u32 {
    const start = tree.tokenStart(token);
    var line: u32 = 1;
    for (tree.source[0..start]) |byte| {
        if (byte == '\n') {
            line += 1;
        }
    }
    return line;
}

test {
    _ = @import("finders.test.zig");
}
