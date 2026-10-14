// Makes every function of a source file public in the copy a run compiles, so the program can call
// each one directly and not only through the public functions of its file. The project's own files
// are never changed. `pub ` goes on the line the declaration is already on, so every line keeps its
// number and the lines kcov reports still match the project's files.

const std = @import("std");
const Ast = std.zig.Ast;

// The source with `pub ` put in front of every function declaration that has none, and in front of
// every `const` holding a struct, union, enum or opaque type that has none, so the methods inside
// it are reached too. Containers are searched at every depth. A source that does not parse is returned
// as it is, because the compiler will say what is wrong with it. The caller owns what is returned.
pub fn makePublic(allocator: std.mem.Allocator, source: [:0]const u8) std.mem.Allocator.Error![]u8 {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        return allocator.dupe(u8, source);
    }

    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);
    try collectOffsets(allocator, tree, tree.rootDecls(), &offsets);

    const inserted = "pub ";
    var made: std.ArrayList(u8) = .empty;
    errdefer made.deinit(allocator);
    try made.ensureTotalCapacity(allocator, source.len + offsets.items.len * inserted.len);
    var copied: usize = 0;
    for (offsets.items) |offset| {
        made.appendSliceAssumeCapacity(source[copied..offset]);
        made.appendSliceAssumeCapacity(inserted);
        copied = offset;
    }
    made.appendSliceAssumeCapacity(source[copied..]);
    return made.toOwnedSlice(allocator);
}

// Adds to `offsets` where `pub ` goes for each of `members` and for the members of every container
// among them, in the order they appear in the source.
fn collectOffsets(allocator: std.mem.Allocator, tree: Ast, members: []const Ast.Node.Index, offsets: *std.ArrayList(usize)) std.mem.Allocator.Error!void {
    for (members) |member| {
        if (tree.nodeTag(member) == .fn_decl) {
            var buffer: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buffer, member) orelse continue;
            if (proto.visib_token == null) {
                try offsets.append(allocator, tree.tokenStart(tree.firstToken(member)));
            }
            continue;
        }
        const declaration = tree.fullVarDecl(member) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(declaration.ast.mut_token), "const")) {
            continue;
        }
        const init_node = declaration.ast.init_node.unwrap() orelse continue;
        var container_buffer: [2]Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&container_buffer, init_node) orelse continue;
        if (declaration.visib_token == null) {
            try offsets.append(allocator, tree.tokenStart(tree.firstToken(member)));
        }
        try collectOffsets(allocator, tree, container.ast.members, offsets);
    }
}

test {
    _ = @import("make_public.test.zig");
}
