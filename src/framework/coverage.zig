// Turns a function's own source into the list of code paths a run has to exercise and ticks them
// from the lines kcov saw run.
//
// A function's source is read with std.zig.Ast. Every branch side in it is one code path: both
// sides of an `if` (with or without an `else`), every `switch` prong, every loop body (and a
// loop's `else`), every `catch` and `orelse` fallback, plus the function's own entry. Each code
// path is given the one line whose execution proves it ran, its witness line. kcov line data is
// the only evidence: a code path is ticked when its witness line ran.
//
// A code path that no line can prove is not a code path here. The false side of an `if` with no
// `else` whose body does not leave has no line of its own, and neither has a body written on the
// same line as its condition, because that line runs whether or not the branch was taken. Those
// are left out of the checklist (and so out of the percentage and out of the list of what is
// unticked) and only counted, in `Checklist.unprovable`. `and`, `or` and `try` are not code paths
// at all.
//
// Only branches written as statements or as a value are found by walking the parser's node array,
// at any depth, including inside `catch` bodies and `defer` bodies. A function declared inside the
// function being read has its own checklist and is not read into this one.

const std = @import("std");
const Ast = std.zig.Ast;
const covered_lines = @import("covered_lines.zig");

// Which lines of one file the build has code for and which of them ran, as read from kcov by
// `covered_lines.zig`. Named here so a checklist can be ticked from one.
pub const LineSet = covered_lines.LineSet;

// One code path of one function: where it is, what it is called and which line proves it ran.
pub const Path = struct {
    // The line of the branch's own controlling token (`if`, a `switch` prong's `=>`, `while`,
    // `for`, `catch`, `orelse`), counted from one the way an editor counts.
    line: u32,

    // A name built from the code path's kind, line and side, such as `if:9:false`,
    // `switch:15:else`, `loop:20:body` or `catch:24:taken`, and `<function>:entered` for the
    // function's entry. Stable across runs on the same source. Owned by the checklist.
    name: []const u8,

    // The line whose execution proves this code path ran: the first statement of the branch's
    // body, or the statement after an `if` whose taken side leaves. Never the line of the
    // condition, and never a line another code path of the same function also uses.
    witness: u32,

    // Whether the build carried no code for `witness`. Set by `markMissingLines` from what kcov
    // listed, so a code path an optimiser folded away is reported as one line coverage cannot see
    // rather than one the run failed to reach.
    line_missing: bool = false,
};

// The code paths of one function and which of them a run has reached. Every string here is owned
// by the checklist and freed by `deinit`, so the source and the Ast it was read from can be freed
// as soon as `build` returns.
pub const Checklist = struct {
    // What `deinit` frees everything here with.
    allocator: std.mem.Allocator,

    // The function this checklist was built from.
    function: []const u8,

    // The file `function` was read from, printed beside every code path so it can be opened.
    file: []const u8,

    // Every code path found, the function's entry first.
    paths: []Path,

    // Parallel to `paths`: whether a run has reached the code path at the same index.
    ticked: []bool,

    // How many branch sides were found that no line can prove. They are in no other field and in
    // no count, so a reader of the report can still be told they were left out.
    unprovable: usize = 0,

    // Frees the strings, the paths and the ticks.
    pub fn deinit(self: *Checklist) void {
        self.allocator.free(self.function);
        self.allocator.free(self.file);
        for (self.paths) |path| {
            self.allocator.free(path.name);
        }
        self.allocator.free(self.paths);
        self.allocator.free(self.ticked);
    }

    // Ticks every code path whose witness line `lines` says ran. A tick is never taken back, so
    // calling this once per run accumulates what every run reached.
    pub fn tickFromLines(self: *Checklist, lines: *const LineSet) void {
        for (self.paths, 0..) |path, index| {
            if (lines.isHit(path.witness)) {
                self.ticked[index] = true;
            }
        }
    }

    // Records, for every unticked code path, whether the build carried code for its witness line
    // at all. A line kcov never listed has no address in the binary, so no run can hit it.
    pub fn markMissingLines(self: *Checklist, lines: *const LineSet) void {
        for (self.paths, 0..) |*path, index| {
            if (self.ticked[index]) {
                continue;
            }
            if (!lines.isCode(path.witness)) {
                path.line_missing = true;
            }
        }
    }

    // Whether every code path has been ticked. A function with no code path at all is complete.
    pub fn allTicked(self: Checklist) bool {
        return self.untickedCount() == 0;
    }

    // How many code paths have been ticked.
    pub fn tickedCount(self: Checklist) usize {
        return self.paths.len - self.untickedCount();
    }

    // How many code paths have not been ticked.
    pub fn untickedCount(self: Checklist) usize {
        var count: usize = 0;
        for (self.ticked) |value| {
            if (!value) {
                count += 1;
            }
        }
        return count;
    }
};

// The two ways reading source fails beyond running out of memory: the text is not valid Zig, or
// it holds no function of the name asked for.
pub const BuildError = std.mem.Allocator.Error || error{ SourceDoesNotParse, FunctionNotFound };

// The one way listing declarations fails beyond running out of memory: the text is not valid Zig.
pub const ListError = std.mem.Allocator.Error || error{SourceDoesNotParse};

// Parses `source` (a whole file is fine, only `function_name`'s own declaration is read) and
// builds the checklist for that one function. Always the first declaration with that name: where
// a file has several (two structs each with a method of the same name) use `buildOccurrence`.
pub fn build(allocator: std.mem.Allocator, file: []const u8, source: [:0]const u8, function_name: []const u8) BuildError!Checklist {
    return buildOccurrence(allocator, file, source, function_name, 0);
}

// Like `build`, but reads the `occurrence`-th (from zero) declaration named `function_name`, in
// the order `listDeclarations` numbers them.
pub fn buildOccurrence(allocator: std.mem.Allocator, file: []const u8, source: [:0]const u8, function_name: []const u8, occurrence: usize) BuildError!Checklist {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return error.SourceDoesNotParse;
    }

    const body = findFunctionBody(tree, function_name, occurrence) orelse return error.FunctionNotFound;
    return buildFromBody(allocator, tree, file, function_name, body);
}

// Builds one checklist for every function `source` declares that runs at run time (a function
// returning `type` is not one), in the order `listDeclarations` lists them. The file is parsed
// once. Free with `freeChecklists`.
pub fn buildFile(allocator: std.mem.Allocator, file: []const u8, source: [:0]const u8) BuildError![]Checklist {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return error.SourceDoesNotParse;
    }

    const found = try declarationsOf(allocator, tree);
    defer {
        for (found) |each| {
            allocator.free(each.declaration.name);
        }
        allocator.free(found);
    }

    var checklists: std.ArrayList(Checklist) = .empty;
    errdefer {
        for (checklists.items) |*checklist| {
            checklist.deinit();
        }
        checklists.deinit(allocator);
    }
    for (found) |each| {
        const body = tree.nodeData(each.node).node_and_node[1];
        var checklist = try buildFromBody(allocator, tree, file, each.declaration.name, body);
        errdefer checklist.deinit();
        try checklists.append(allocator, checklist);
    }
    return checklists.toOwnedSlice(allocator);
}

// Frees a slice `buildFile` returned and every checklist in it.
pub fn freeChecklists(allocator: std.mem.Allocator, checklists: []Checklist) void {
    for (checklists) |*checklist| {
        checklist.deinit();
    }
    allocator.free(checklists);
}

// Reads the code paths out of one function's body block.
fn buildFromBody(allocator: std.mem.Allocator, tree: Ast, file: []const u8, function_name: []const u8, body: Ast.Node.Index) BuildError!Checklist {
    var candidates: std.ArrayList(Candidate) = .empty;
    defer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.name);
        }
        candidates.deinit(allocator);
    }

    // A function with an empty body has nothing to run, so it has no code path rather than an
    // entry nothing could ever prove.
    var statements_buffer: [2]Ast.Node.Index = undefined;
    const has_statements = if (tree.blockStatements(&statements_buffer, body)) |statements| statements.len != 0 else true;

    if (has_statements) {
        // The function's own body is a code path: running it at all. The branches found below are
        // the ways that path can differ. Without it a function with no `if`, `switch` or loop would
        // have no code path, and a function nothing called would look like one that ran.
        const opening_line = lineOf(tree, tree.firstToken(body));
        try candidates.append(allocator, .{
            .line = opening_line,
            .name = try std.fmt.allocPrint(allocator, "{s}:entered", .{function_name}),
            .witness = witnessFor(tree, body, opening_line),
        });
        try walkEveryBranch(allocator, tree, body, &candidates);
        dropSharedWitnesses(candidates.items);
    }

    var paths: std.ArrayList(Path) = .empty;
    errdefer {
        for (paths.items) |path| {
            allocator.free(path.name);
        }
        paths.deinit(allocator);
    }
    var unprovable: usize = 0;
    for (candidates.items) |*candidate| {
        const witness = candidate.witness orelse {
            unprovable += 1;
            continue;
        };
        try paths.append(allocator, .{ .line = candidate.line, .name = candidate.name, .witness = witness });
        // Ownership of the name has moved to `paths`; empty it so the cleanup above skips it.
        candidate.name = &.{};
    }

    const function = try allocator.dupe(u8, function_name);
    errdefer allocator.free(function);
    const file_copy = try allocator.dupe(u8, file);
    errdefer allocator.free(file_copy);
    const owned_paths = try paths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_paths);
    const ticked = try allocator.alloc(bool, owned_paths.len);
    @memset(ticked, false);

    return .{
        .allocator = allocator,
        .function = function,
        .file = file_copy,
        .paths = owned_paths,
        .ticked = ticked,
        .unprovable = unprovable,
    };
}

// A code path as the walk finds it, before it is known whether a line can prove it.
const Candidate = struct {
    // As `Path.line`.
    line: u32,

    // As `Path.name`. Owned by whoever holds the candidate.
    name: []const u8,

    // The line that proves it ran, or null where none can.
    witness: ?u32,
};

// What a run has ticked and left unticked across every checklist, in the words the checklist
// needs. Every slice borrows from the checklist it came from.
pub const UntickedPath = struct {
    // The file the function is in.
    file: []const u8,

    // The function the code path is in.
    function: []const u8,

    // The line of the code path's branch.
    line: u32,

    // The code path's name, such as `if:9:false`.
    name: []const u8,

    // Whether the build had no code for the line that proves it, so no run could ever tick it.
    line_missing: bool,
};

// Every code path of every checklist that is not ticked, in checklist order and then path order.
// The slice is owned by the caller and freed with `allocator.free`. Its strings point into
// `checklists` and live as long as they do.
pub fn listUnticked(allocator: std.mem.Allocator, checklists: []const Checklist) std.mem.Allocator.Error![]UntickedPath {
    var found: std.ArrayList(UntickedPath) = .empty;
    errdefer found.deinit(allocator);
    for (checklists) |checklist| {
        for (checklist.paths, 0..) |path, index| {
            if (checklist.ticked[index]) {
                continue;
            }
            try found.append(allocator, .{
                .file = checklist.file,
                .function = checklist.function,
                .line = path.line,
                .name = path.name,
                .line_missing = path.line_missing,
            });
        }
    }
    return found.toOwnedSlice(allocator);
}

// Ticks every checklist from what kcov reported and marks the code paths whose line the build has
// no code for. `sources_root` is the directory holding the copies of the sources the run was built
// from, which is how a reported file name is matched to a checklist's file. A checklist whose file
// kcov did not report at all is left as it was, since nothing says which of its lines ran.
pub fn tickFromCovered(checklists: []Checklist, covered: *const covered_lines.CoveredLines, sources_root: []const u8) void {
    for (checklists) |*checklist| {
        const lines = covered.linesFor(sources_root, checklist.file) orelse continue;
        checklist.tickFromLines(lines);
        checklist.markMissingLines(lines);
    }
}

// How many code paths there are and how many of them have been ticked.
pub const Counts = struct {
    // Code paths ticked.
    ticked: usize,

    // Every code path.
    total: usize,
};

// Adds up the ticked and the total code paths of every checklist.
pub fn countPaths(checklists: []const Checklist) Counts {
    var counts: Counts = .{ .ticked = 0, .total = 0 };
    for (checklists) |checklist| {
        counts.ticked += checklist.tickedCount();
        counts.total += checklist.paths.len;
    }
    return counts;
}

// What fraction of the code paths ran, rounded down so a run one code path short never reads as
// 100%. A run with no code path has none it failed to reach, so it is 100%.
pub fn percentageOf(ticked: usize, total: usize) usize {
    if (total == 0) {
        return 100;
    }
    return ticked * 100 / total;
}

// One function declaration found in a file: its name, the line its name sits on and which
// same-named declaration in the file it is (zero for the first, one for the next, in the order
// `buildOccurrence` counts them). The name is owned by whoever holds the slice `listDeclarations`
// returned and freed by `freeDeclarations`.
pub const Declaration = struct {
    // The function's name.
    name: []const u8,

    // The line the name sits on.
    line: u32,

    // Which declaration of this name in the file this is, counting from zero.
    occurrence: usize,

    // Whether code outside the file can call it. A private function can only run through a
    // public function of its own file.
    is_public: bool = false,
};

// A declaration and the node it was read from.
const FoundDeclaration = struct {
    // As returned to callers.
    declaration: Declaration,

    // The `fn_decl` node.
    node: Ast.Node.Index,
};

// Every function `tree` declares that can run at run time, wherever it sits (top level or inside
// a container), in the order the node array holds them. A function returning `type` runs while
// the program is being compiled, so it has no run to prove and is left out.
fn declarationsOf(allocator: std.mem.Allocator, tree: Ast) std.mem.Allocator.Error![]FoundDeclaration {
    var found: std.ArrayList(FoundDeclaration) = .empty;
    errdefer {
        for (found.items) |each| {
            allocator.free(each.declaration.name);
        }
        found.deinit(allocator);
    }

    // Counts, per name, how many declarations this walk has already found, which stamps each with
    // the same `occurrence` `findFunctionBody` counts up to before finding it. Declarations
    // returning `type` are counted too, so the two walks agree on the number.
    var seen_counts = std.StringHashMap(usize).init(allocator);
    defer seen_counts.deinit();

    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) {
            continue;
        }
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&proto_buffer, node) orelse continue;
        const name_token = proto.name_token orelse continue;
        const name = tree.tokenSlice(name_token);

        const seen = try seen_counts.getOrPut(name);
        if (!seen.found_existing) {
            seen.value_ptr.* = 0;
        }
        const occurrence = seen.value_ptr.*;
        seen.value_ptr.* = occurrence + 1;

        if (proto.ast.return_type.unwrap()) |return_type| {
            if (tree.nodeTag(return_type) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(return_type)), "type")) {
                continue;
            }
        }

        try found.append(allocator, .{
            .declaration = .{
                .name = try allocator.dupe(u8, name),
                .line = lineOf(tree, name_token),
                .occurrence = occurrence,
                .is_public = proto.visib_token != null,
            },
            .node = node,
        });
    }
    return found.toOwnedSlice(allocator);
}

// Every `fn` declaration `source` holds that runs at run time, in the order the parser holds them.
// Free with `freeDeclarations`.
pub fn listDeclarations(allocator: std.mem.Allocator, source: [:0]const u8) ListError![]const Declaration {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return error.SourceDoesNotParse;
    }

    const found = try declarationsOf(allocator, tree);
    defer allocator.free(found);

    const declarations = allocator.alloc(Declaration, found.len) catch |err| {
        for (found) |each| {
            allocator.free(each.declaration.name);
        }
        return err;
    };
    for (found, 0..) |each, index| {
        declarations[index] = each.declaration;
    }
    return declarations;
}

// Frees a slice `listDeclarations` returned, including every name in it.
pub fn freeDeclarations(allocator: std.mem.Allocator, declarations: []const Declaration) void {
    for (declarations) |declaration| {
        allocator.free(declaration.name);
    }
    allocator.free(declarations);
}

// Finds the `occurrence`-th `fn_decl` named `function_name` anywhere in the tree (a top-level
// function or one inside a container are both `fn_decl` nodes in a flat array) and returns its
// body block.
fn findFunctionBody(tree: Ast, function_name: []const u8, occurrence: usize) ?Ast.Node.Index {
    var index: u32 = 0;
    var seen: usize = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) {
            continue;
        }
        var proto_buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&proto_buffer, node) orelse continue;
        const name_token = proto.name_token orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(name_token), function_name)) {
            if (seen == occurrence) {
                return tree.nodeData(node).node_and_node[1];
            }
            seen += 1;
        }
    }
    return null;
}

// The line a person reading the source calls this token's line. `Ast.tokenLocation` counts from
// zero and every editor, `@src().line` and kcov count from one.
fn lineOf(tree: Ast, token: Ast.TokenIndex) u32 {
    return @intCast(tree.tokenLocation(0, token).line + 1);
}

// Every kind of branch `syntheticName` can name, for a caller telling a synthesized name from
// another by reading this list rather than repeating it.
pub const synthesized_kinds = [_][]const u8{ "if:", "loop:", "switch:", "catch:", "orelse:" };

// Builds the name a branch side gets from its kind, line and side: `if:42:true`,
// `switch:50:.connection_refused`, `loop:60:body`. Stable across runs on the same source.
fn syntheticName(allocator: std.mem.Allocator, kind: []const u8, line: u32, side: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ kind, line, side });
}

// One branch side, named and given the line that proves it.
//
// `controlling_line` is the line of the token that decides this branch (`if`, `switch`, `while`,
// `for`, `catch`, `orelse`). It runs whether or not the branch is taken, so a body starting on it
// has no line that proves it and the witness is null.
fn candidateFor(
    allocator: std.mem.Allocator,
    tree: Ast,
    body: Ast.Node.Index,
    kind: []const u8,
    line: u32,
    side: []const u8,
    controlling_line: u32,
) std.mem.Allocator.Error!Candidate {
    return .{
        .line = line,
        .name = try syntheticName(allocator, kind, line, side),
        .witness = witnessFor(tree, body, controlling_line),
    };
}

// The line whose execution proves `body` ran: its first statement's line for a block with
// statements, otherwise the line its own first token sits on. Null when that is
// `controlling_line`, since that line runs whether or not the branch is taken.
fn witnessFor(tree: Ast, body: Ast.Node.Index, controlling_line: u32) ?u32 {
    const line = witnessLineOf(tree, body);
    if (line == controlling_line) {
        return null;
    }
    return line;
}

// The line kcov attributes the start of `body` to: the first statement of a block with
// statements, or the first token of anything else.
fn witnessLineOf(tree: Ast, body: Ast.Node.Index) u32 {
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.blockStatements(&buffer, body)) |statements| {
        if (statements.len != 0) {
            return lineOf(tree, tree.firstToken(statements[0]));
        }
    }
    return lineOf(tree, tree.firstToken(body));
}

// The statement that follows `node` in the block holding it, or null when `node` is the last
// statement of its block or stands in no block. The innermost block wins, so an `if` inside a loop
// body is followed by the loop body's next statement rather than whatever follows the loop.
fn statementAfter(tree: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    var innermost: ?Ast.Node.Index = null;
    var innermost_span: u32 = std.math.maxInt(u32);
    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const candidate: Ast.Node.Index = @enumFromInt(index);
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, candidate) orelse continue;
        var position: ?usize = null;
        for (statements, 0..) |statement, at| {
            if (statement == node) {
                position = at;
            }
        }
        const found = position orelse continue;
        const span = tree.lastToken(candidate) - tree.firstToken(candidate);
        if (span >= innermost_span) {
            continue;
        }
        innermost_span = span;
        // Taken now rather than kept as a slice: `statements` may point into `buffer`, which the
        // next candidate overwrites.
        innermost = if (found + 1 < statements.len) statements[found + 1] else null;
    }
    return innermost;
}

// A line two code paths of one function both point at proves neither: a run that hit it took one
// of the two and the line does not say which. Both lose their witness. Run once the whole function
// has been walked, because the code paths sharing a line can sit in different branches.
fn dropSharedWitnesses(candidates: []Candidate) void {
    for (candidates, 0..) |candidate, index| {
        const line = candidate.witness orelse continue;
        var is_shared = false;
        for (candidates, 0..) |other, other_index| {
            if (other_index != index and other.witness == line) {
                is_shared = true;
            }
        }
        if (!is_shared) {
            continue;
        }
        for (candidates) |*each| {
            if (each.witness == line) {
                each.witness = null;
            }
        }
    }
}

// The false side of an `if` that has no `else`: the condition did not hold and the code carried
// on past the `if`. Where the taken side leaves the function or the loop, the statement after the
// `if` runs only when the condition did not hold, so its line proves this side. Where the taken
// side carries on, both sides meet at that statement and no line says which happened, so the
// witness is null and the side is left out of the count.
fn candidateWithNoElse(
    allocator: std.mem.Allocator,
    tree: Ast,
    node: Ast.Node.Index,
    if_full: Ast.full.If,
    line: u32,
) std.mem.Allocator.Error!Candidate {
    var witness: ?u32 = null;
    if (takenSideLeaves(tree, if_full.ast.then_expr)) {
        if (statementAfter(tree, node)) |next| {
            witness = witnessFor(tree, next, line);
        }
    }
    return .{
        .line = line,
        .name = try syntheticName(allocator, "if", line, "false"),
        .witness = witness,
    };
}

// Whether taking this branch means leaving: the body is, or ends in, a `return`, a `break`, a
// `continue` or a stop, so nothing after the `if` runs when it is taken.
fn takenSideLeaves(tree: Ast, body: Ast.Node.Index) bool {
    if (leaves(tree, body)) {
        return true;
    }
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return false;
    if (statements.len == 0) {
        return false;
    }
    return leaves(tree, statements[statements.len - 1]);
}

// Whether one statement leaves the block it is in.
fn leaves(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue" => true,
        else => isStop(tree, node),
    };
}

// One switch prong's label read off its values: the source text of each joined with `, `, or
// `else` for the catch-all prong.
fn caseLabel(allocator: std.mem.Allocator, tree: Ast, case: Ast.full.SwitchCase) std.mem.Allocator.Error![]const u8 {
    if (case.ast.values.len == 0) {
        return allocator.dupe(u8, "else");
    }
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (case.ast.values, 0..) |value, index| {
        if (index > 0) {
            try text.appendSlice(allocator, ", ");
        }
        try text.appendSlice(allocator, tree.getNodeSource(value));
    }
    return text.toOwnedSlice(allocator);
}

// A range of tokens inside which nothing is a code path of the function being read: a function
// declared inside it has a checklist of its own.
const Span = struct {
    // The first token of the span.
    first: Ast.TokenIndex,

    // The last token of the span.
    last: Ast.TokenIndex,
};

// Whether the token range `first` to `last` lies inside any of `spans`.
fn isWithinAny(spans: []const Span, first: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    for (spans) |span| {
        if (first >= span.first and last <= span.last) {
            return true;
        }
    }
    return false;
}

// Every branch side in `body`, wherever it is written. The walk is over the parser's node array
// rather than over statements, because a branch is a branch whether it stands as a statement or
// sits inside an expression: an `if` inside a `catch` body, a `switch` that is the value of a
// `return`, an `orelse` fallback.
fn walkEveryBranch(allocator: std.mem.Allocator, tree: Ast, body: Ast.Node.Index, candidates: *std.ArrayList(Candidate)) std.mem.Allocator.Error!void {
    const body_first = tree.firstToken(body);
    const body_last = tree.lastToken(body);

    var skipped: std.ArrayList(Span) = .empty;
    defer skipped.deinit(allocator);

    var index: u32 = 0;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (first < body_first or last > body_last) {
            continue;
        }
        if (tree.nodeTag(node) == .fn_decl) {
            try skipped.append(allocator, .{ .first = first, .last = last });
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
        if (isWithinAny(skipped.items, first, last)) {
            continue;
        }

        if (tree.fullIf(node)) |if_full| {
            const line = lineOf(tree, if_full.ast.if_token);
            if (!isUnreachableBody(tree, if_full.ast.then_expr)) {
                try candidates.append(allocator, try candidateFor(allocator, tree, if_full.ast.then_expr, "if", line, "true", line));
            }

            if (if_full.ast.else_expr.unwrap()) |else_expr| {
                if (!isUnreachableBody(tree, else_expr)) {
                    // The `if` line is the one that decides this side too: `} else if (c) {` puts
                    // the next condition on the `else` line, and that line runs only when this
                    // side was taken, so it is a witness rather than a line to rule out.
                    const at = lineOf(tree, tree.firstToken(else_expr));
                    try candidates.append(allocator, try candidateFor(allocator, tree, else_expr, "if", at, "false", line));
                }
            } else {
                try candidates.append(allocator, try candidateWithNoElse(allocator, tree, node, if_full, line));
            }
            continue;
        }

        if (tree.fullSwitch(node)) |switch_full| {
            // The `switch` keyword's line is where the choice is made, so a prong answering with a
            // value on that same line has no line of its own. A prong on a line below does, even
            // when it is a bare expression.
            const switch_line = lineOf(tree, tree.nodeMainToken(node));
            for (switch_full.ast.cases) |case_node| {
                const case_full = tree.fullSwitchCase(case_node) orelse continue;
                if (isUnreachableBody(tree, case_full.ast.target_expr)) {
                    continue;
                }
                const line = lineOf(tree, case_full.ast.arrow_token);
                const label = try caseLabel(allocator, tree, case_full);
                defer allocator.free(label);
                try candidates.append(allocator, try candidateFor(allocator, tree, case_full.ast.target_expr, "switch", line, label, switch_line));
            }
            continue;
        }

        const loop_body = if (tree.fullWhile(node)) |while_full|
            while_full.ast.then_expr
        else if (tree.fullFor(node)) |for_full|
            for_full.ast.then_expr
        else
            null;
        if (loop_body) |body_node| {
            const line = lineOf(tree, tree.nodeMainToken(node));
            try candidates.append(allocator, try candidateFor(allocator, tree, body_node, "loop", line, "body", line));
            // A loop's own `else` runs when it finished without breaking, which no count of
            // iterations can tell apart from breaking on the last one, so it is a code path of its
            // own.
            const loop_else = if (tree.fullWhile(node)) |while_full|
                while_full.ast.else_expr
            else if (tree.fullFor(node)) |for_full|
                for_full.ast.else_expr
            else
                .none;
            if (loop_else.unwrap()) |else_expr| {
                if (!isUnreachableBody(tree, else_expr)) {
                    const else_line = lineOf(tree, tree.firstToken(else_expr));
                    try candidates.append(allocator, try candidateFor(allocator, tree, else_expr, "loop", else_line, "completed", line));
                }
            }
            continue;
        }

        // `catch` and `orelse` are branches wherever they appear and are always expressions, so
        // a statement walk would never see either. One code path each: the fallback ran.
        const fallback_kind: ?[]const u8 = switch (tree.nodeTag(node)) {
            .@"catch" => "catch",
            .@"orelse" => "orelse",
            else => null,
        };
        if (fallback_kind) |kind| {
            const line = lineOf(tree, tree.nodeMainToken(node));
            const fallback = tree.nodeData(node).node_and_node[1];
            if (isUnreachableBody(tree, fallback)) {
                continue;
            }
            try candidates.append(allocator, try candidateFor(allocator, tree, fallback, kind, line, "taken", line));
        }
    }
}

// Whether a branch's body is `unreachable`, either bare or as a block holding nothing else. Such
// a branch asserts it cannot be taken, and the language checks that: a run that takes it panics in
// a safe build. There is nothing for a run to reach, so it is not a code path.
fn isUnreachableBody(tree: Ast, node: Ast.Node.Index) bool {
    if (isStop(tree, node)) {
        return true;
    }
    var statements_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&statements_buffer, node) orelse return false;
    return statements.len == 1 and isStop(tree, statements[0]);
}

// Whether one statement says the branch holding it cannot be taken: `unreachable`, a `@panic`
// that ends the run, or a `@compileError` that stops the build before there is a run at all.
fn isStop(tree: Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) == .unreachable_literal) {
        return true;
    }
    if (tree.nodeTag(node) != .builtin_call_two and tree.nodeTag(node) != .builtin_call_two_comma) {
        return false;
    }
    const called = tree.tokenSlice(tree.nodeMainToken(node));
    return std.mem.eql(u8, called, "@panic") or std.mem.eql(u8, called, "@compileError");
}

test {
    _ = @import("coverage.test.zig");
}
