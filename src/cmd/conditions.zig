// Reads the conditions in one function with `std.zig.Ast`, so the value chooser can try values on
// each side of every constant a function compares against. Faultline does not follow a value through
// the function: it reads each comparison, switch prong, optional check and error check and reports
// the constant it tests and the source text of the other side.

const std = @import("std");
const Ast = std.zig.Ast;
const condition = @import("../framework/condition.zig");

// The condition types are shared with the value chooser, so they live in one file of their own.
pub const Condition = condition.Condition;
pub const Literal = condition.Literal;
pub const Kind = condition.Kind;
pub const Operator = condition.Operator;

// Why the conditions of a function could not be read.
pub const ReadError = error{
    // The source does not parse as Zig.
    SourceDoesNotParse,

    // No function with that name is declared in the source.
    FunctionNotFound,
} || std.mem.Allocator.Error;

// How a token range inside the tree is kept while the walk decides which nodes belong to a function
// and which to a function declared inside it.
const Span = struct {
    // The first token of the range.
    first: Ast.TokenIndex,

    // The last token of the range.
    last: Ast.TokenIndex,
};

// Every condition in every function named `function_name` in `source`, in line order.
//
// A comparison with the constant on the left (`3 < x`) is reported as if the constant were on the
// right (`x > 3`), so the operator always reads as "subject, operator, literal". A comparison with no
// constant on either side is not reported, because there is nothing to try values around. When a file
// declares several functions with one name (the same method on two structs) the conditions of all of
// them are returned, which only widens the values tried.
//
// The strings in the result are owned by the caller and `subject` slices point into `source`, which
// has to outlive the result. `freeConditions` releases the result.
pub fn conditionsIn(allocator: std.mem.Allocator, source: [:0]const u8, function_name: []const u8) ReadError![]condition.Condition {
    var tree = Ast.parse(allocator, source, .zig) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return error.SourceDoesNotParse;
    }

    var found: std.ArrayList(condition.Condition) = .empty;
    errdefer freeConditionList(allocator, &found);

    var function_seen = false;
    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) {
            continue;
        }
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&proto_buffer, node) orelse continue;
        const name_token = proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), function_name)) {
            continue;
        }
        function_seen = true;
        const body = tree.nodeData(node).node_and_node[1];
        try readBody(allocator, tree, body, &found);
    }

    if (!function_seen) {
        return error.FunctionNotFound;
    }

    std.mem.sort(condition.Condition, found.items, {}, isEarlier);
    return found.toOwnedSlice(allocator);
}

// Releases what `conditionsIn` returned.
pub fn freeConditions(allocator: std.mem.Allocator, conditions: []condition.Condition) void {
    for (conditions) |item| {
        if (item.literal) |literal| {
            switch (literal) {
                .string => |text| allocator.free(text),
                else => {},
            }
        }
    }
    allocator.free(conditions);
}

// Releases a list that is still being built.
fn freeConditionList(allocator: std.mem.Allocator, list: *std.ArrayList(condition.Condition)) void {
    for (list.items) |item| {
        if (item.literal) |literal| {
            switch (literal) {
                .string => |text| allocator.free(text),
                else => {},
            }
        }
    }
    list.deinit(allocator);
}

// Whether one condition comes before another: by line, with equal lines kept in source order by the
// stable sort.
fn isEarlier(_: void, a: condition.Condition, b: condition.Condition) bool {
    return a.line < b.line;
}

// Reads every condition in one function body, leaving out functions declared inside it.
fn readBody(allocator: std.mem.Allocator, tree: Ast, body: Ast.Node.Index, found: *std.ArrayList(condition.Condition)) ReadError!void {
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);

    var nested: std.ArrayList(Span) = .empty;
    defer nested.deinit(allocator);

    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) {
            continue;
        }
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first > body_first and last <= body_last) {
            try nested.append(allocator, .{ .first = first, .last = last });
        }
    }

    index = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) {
            continue;
        }
        if (isInsideAny(nested.items, first, last)) {
            continue;
        }
        try readNode(allocator, tree, node, found);
    }
}

// Whether a token range lies inside any of the ranges.
fn isInsideAny(spans: []const Span, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (first >= span.first and last <= span.last) {
            return true;
        }
    }
    return false;
}

// Adds the conditions one node holds, if it holds any.
fn readNode(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, found: *std.ArrayList(condition.Condition)) ReadError!void {
    switch (tree.nodeTag(node)) {
        .equal_equal => try readComparison(allocator, tree, node, .equal, found),
        .bang_equal => try readComparison(allocator, tree, node, .not_equal, found),
        .less_than => try readComparison(allocator, tree, node, .less, found),
        .less_or_equal => try readComparison(allocator, tree, node, .less_equal, found),
        .greater_than => try readComparison(allocator, tree, node, .greater, found),
        .greater_or_equal => try readComparison(allocator, tree, node, .greater_equal, found),
        .@"orelse" => {
            const left = tree.nodeData(node).node_and_node[0];
            try found.append(allocator, .{
                .line = lineOf(tree, tree.nodeMainToken(node)),
                .kind = .optional_check,
                .literal = .null_value,
                .subject = tree.getNodeSource(left),
            });
        },
        .@"catch" => {
            const left = tree.nodeData(node).node_and_node[0];
            try found.append(allocator, .{
                .line = lineOf(tree, tree.nodeMainToken(node)),
                .kind = .error_check,
                .subject = tree.getNodeSource(left),
            });
        },
        .switch_comma, .@"switch" => try readSwitch(allocator, tree, node, found),
        .call_one, .call_one_comma, .call, .call_comma => try readCall(allocator, tree, node, found),
        else => {
            if (tree.fullIf(node)) |if_full| {
                try readIf(allocator, tree, if_full, found);
            } else if (tree.fullWhile(node)) |while_full| {
                try readWhile(allocator, tree, while_full, found);
            }
        },
    }
}

// A comparison against a constant, the constant being on either side. A constant `null` makes it an
// optional check and a constant `error.Name` makes it an error check.
fn readComparison(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, operator: Operator, found: *std.ArrayList(condition.Condition)) ReadError!void {
    const sides = tree.nodeData(node).node_and_node;
    const line = lineOf(tree, tree.nodeMainToken(node));

    for ([_]bool{ true, false }) |constant_on_right| {
        const constant = if (constant_on_right) sides[1] else sides[0];
        const subject = if (constant_on_right) sides[0] else sides[1];
        const used_operator = if (constant_on_right) operator else mirrored(operator);

        if (isErrorValue(tree, constant)) {
            try found.append(allocator, .{
                .line = line,
                .kind = .error_check,
                .operator = used_operator,
                .subject = tree.getNodeSource(subject),
            });
            return;
        }

        const literal = (try readLiteral(allocator, tree, constant)) orelse continue;
        errdefer freeLiteral(allocator, literal);
        const kind: Kind = switch (literal) {
            .null_value => .optional_check,
            else => .comparison,
        };
        try found.append(allocator, .{
            .line = line,
            .kind = kind,
            .operator = used_operator,
            .literal = literal,
            .subject = tree.getNodeSource(subject),
        });
        return;
    }
}

// The operator that means the same thing with its two sides swapped.
fn mirrored(operator: Operator) Operator {
    return switch (operator) {
        .equal => .equal,
        .not_equal => .not_equal,
        .less => .greater,
        .less_equal => .greater_equal,
        .greater => .less,
        .greater_equal => .less_equal,
    };
}

// Releases a literal this file allocated.
fn freeLiteral(allocator: std.mem.Allocator, literal: Literal) void {
    switch (literal) {
        .string => |text| allocator.free(text),
        else => {},
    }
}

// Whether a node is `error.Name`.
fn isErrorValue(tree: Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .error_value;
}

// The call forms that are conditions: `std.mem.eql`, `std.mem.startsWith` and `std.mem.endsWith`
// against a string literal.
fn readCall(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, found: *std.ArrayList(condition.Condition)) ReadError!void {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return;
    const callee = tree.getNodeSource(call.ast.fn_expr);

    const kind: Kind = if (isCallTo(callee, "eql"))
        .string_equals
    else if (isCallTo(callee, "startsWith"))
        .string_starts_with
    else if (isCallTo(callee, "endsWith"))
        .string_ends_with
    else
        return;

    // The call is `(type, a, b)`: the type is the first argument and the two strings follow.
    if (call.ast.params.len != 3) {
        return;
    }
    const first = call.ast.params[1];
    const second = call.ast.params[2];

    for ([_]bool{ true, false }) |constant_is_second| {
        const constant = if (constant_is_second) second else first;
        const subject = if (constant_is_second) first else second;
        const literal = (try readLiteral(allocator, tree, constant)) orelse continue;
        errdefer freeLiteral(allocator, literal);
        switch (literal) {
            .string => {},
            else => {
                freeLiteral(allocator, literal);
                continue;
            },
        }
        try found.append(allocator, .{
            .line = lineOf(tree, tree.firstToken(node)),
            .kind = kind,
            .literal = literal,
            .subject = tree.getNodeSource(subject),
        });
        return;
    }
}

// Whether the callee text names `std.mem.<name>`, written in full or through a `mem` alias.
fn isCallTo(callee: []const u8, name: []const u8) bool {
    if (callee.len <= name.len or !std.mem.endsWith(u8, callee, name)) {
        return false;
    }
    const before = callee[0 .. callee.len - name.len];
    return std.mem.eql(u8, before, "std.mem.") or std.mem.eql(u8, before, "mem.");
}

// One condition per value of every prong of a switch and one for an `else` prong.
fn readSwitch(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index, found: *std.ArrayList(condition.Condition)) ReadError!void {
    const switch_full = tree.fullSwitch(node) orelse return;
    const subject = tree.getNodeSource(switch_full.ast.condition);

    for (switch_full.ast.cases) |case_node| {
        const case = tree.fullSwitchCase(case_node) orelse continue;
        if (case.ast.values.len == 0) {
            try found.append(allocator, .{
                .line = lineOf(tree, case.ast.arrow_token),
                .kind = .switch_prong,
                .subject = subject,
            });
            continue;
        }
        for (case.ast.values) |value| {
            var target = value;
            if (tree.nodeTag(value) == .switch_range) {
                target = tree.nodeData(value).node_and_node[0];
            }
            const literal = try readLiteral(allocator, tree, target);
            errdefer {
                if (literal) |item| {
                    freeLiteral(allocator, item);
                }
            }
            try found.append(allocator, .{
                .line = lineOf(tree, tree.firstToken(value)),
                .kind = .switch_prong,
                .literal = literal,
                .subject = subject,
            });
        }
    }
}

// `if (x) |value|` is an optional check and `if (x) |value| ... else |err|` an error check.
fn readIf(allocator: std.mem.Allocator, tree: Ast, if_full: Ast.full.If, found: *std.ArrayList(condition.Condition)) ReadError!void {
    const kind: Kind = if (if_full.error_token != null)
        .error_check
    else if (if_full.payload_token != null)
        .optional_check
    else
        return;
    try found.append(allocator, .{
        .line = lineOf(tree, if_full.ast.if_token),
        .kind = kind,
        .literal = if (kind == .optional_check) .null_value else null,
        .subject = tree.getNodeSource(if_full.ast.cond_expr),
    });
}

// `while (x) |value|` loops while an optional holds a value and `while (x) |value| ... else |err|`
// loops while an error union holds a value.
fn readWhile(allocator: std.mem.Allocator, tree: Ast, while_full: Ast.full.While, found: *std.ArrayList(condition.Condition)) ReadError!void {
    const kind: Kind = if (while_full.error_token != null)
        .error_check
    else if (while_full.payload_token != null)
        .optional_check
    else
        return;
    try found.append(allocator, .{
        .line = lineOf(tree, while_full.ast.while_token),
        .kind = kind,
        .literal = if (kind == .optional_check) .null_value else null,
        .subject = tree.getNodeSource(while_full.ast.cond_expr),
    });
}

// The constant a node is, or null when it is not one. Looks through parentheses.
//
// An `Upper.name` field access is taken for an enum tag, because the source does not say whether the
// left side is an enum or a namespace of constants and a name starting with a capital letter is a
// type by Zig's own convention.
fn readLiteral(allocator: std.mem.Allocator, tree: Ast, node: Ast.Node.Index) ReadError!?Literal {
    switch (tree.nodeTag(node)) {
        .grouped_expression => {
            return readLiteral(allocator, tree, tree.nodeData(node).node_and_token[0]);
        },
        .number_literal => {
            return numberFrom(tree.tokenSlice(tree.nodeMainToken(node)), false);
        },
        .negation => {
            const operand = tree.nodeData(node).node;
            if (tree.nodeTag(operand) != .number_literal) {
                return null;
            }
            return numberFrom(tree.tokenSlice(tree.nodeMainToken(operand)), true);
        },
        .char_literal => {
            const parsed = std.zig.string_literal.parseCharLiteral(tree.tokenSlice(tree.nodeMainToken(node)));
            switch (parsed) {
                .success => |code_point| return .{ .int = code_point },
                .failure => return null,
            }
        },
        .string_literal => {
            const text = std.zig.string_literal.parseAlloc(allocator, tree.tokenSlice(tree.nodeMainToken(node))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidLiteral => return null,
            };
            return .{ .string = text };
        },
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "true")) {
                return .{ .boolean = true };
            }
            if (std.mem.eql(u8, name, "false")) {
                return .{ .boolean = false };
            }
            if (std.mem.eql(u8, name, "null")) {
                return .null_value;
            }
            return null;
        },
        .enum_literal => {
            return .{ .enum_tag = tree.tokenSlice(tree.nodeMainToken(node)) };
        },
        .field_access => {
            const base, const name_token = tree.nodeData(node).node_and_token;
            if (tree.nodeTag(base) != .identifier) {
                return null;
            }
            const base_name = tree.tokenSlice(tree.nodeMainToken(base));
            if (base_name.len == 0 or !std.ascii.isUpper(base_name[0])) {
                return null;
            }
            return .{ .enum_tag = tree.tokenSlice(name_token) };
        },
        else => return null,
    }
}

// An integer or floating point literal from its text, negated when `negative` is set. Null when the
// text is neither, or is an integer too large for the literal type.
fn numberFrom(text: []const u8, negative: bool) ?Literal {
    switch (std.zig.number_literal.parseNumberLiteral(text)) {
        .int => |value| {
            const wide: i128 = value;
            return .{ .int = if (negative) -wide else wide };
        },
        .float => {
            const value = std.fmt.parseFloat(f64, text) catch return null;
            return .{ .float = if (negative) -value else value };
        },
        .big_int, .failure => return null,
    }
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
    _ = @import("conditions.test.zig");
}
