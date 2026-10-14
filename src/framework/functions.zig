// Finds the functions a source file offers to be called, by reflecting on the namespace of the file
// at compile time.
//
// Two kinds are found: public functions declared at the top of the file, and public methods of
// public structs declared at the top of the file. The build makes every function and container of
// a file that is fault tested public in the copy it compiles (`src/cmd/make_public.zig`), so the
// project's private ones are found too. A method is found only when its first parameter is the
// struct or a pointer to it, because the receiver is built from the struct. Functions that take a
// type parameter or are generic in another way are found too: whether they can be called is
// decided by what builds their arguments, not here.

const std = @import("std");

// One function a file offers.
pub const Found = struct {
    // The name the function is declared with.
    name: []const u8,

    // The name of the struct the function is a method of, or null for a function at the top of
    // the file.
    owner: ?[]const u8,

    // The name a report and a replay token use: `name`, or `Owner.name` for a method.
    pub fn qualifiedName(self: Found, buffer: []u8) []const u8 {
        if (self.owner) |owner| {
            return std.fmt.bufPrint(buffer, "{s}.{s}", .{ owner, self.name }) catch self.name;
        }
        return self.name;
    }
};

// The functions of `Namespace`, in declaration order. Evaluated at compile time.
pub fn listIn(comptime Namespace: type) []const Found {
    comptime {
        var found: []const Found = &.{};
        const info = @typeInfo(Namespace);
        if (info != .@"struct") {
            return found;
        }
        for (info.@"struct".decls) |declaration| {
            if (!@hasDecl(Namespace, declaration.name)) {
                continue;
            }
            const value = @field(Namespace, declaration.name);
            const Type = @TypeOf(value);
            if (@typeInfo(Type) == .@"fn") {
                found = found ++ [1]Found{.{ .name = declaration.name, .owner = null }};
            } else if (Type == type and isStruct(value)) {
                found = found ++ methodsOf(value, declaration.name);
            }
        }
        return found;
    }
}

fn isStruct(comptime Candidate: type) bool {
    return @typeInfo(Candidate) == .@"struct";
}

// The public methods of `Owner` whose first parameter is the struct or a pointer to it.
fn methodsOf(comptime Owner: type, comptime owner_name: []const u8) []const Found {
    comptime {
        var found: []const Found = &.{};
        for (@typeInfo(Owner).@"struct".decls) |declaration| {
            const value = @field(Owner, declaration.name);
            const Type = @TypeOf(value);
            if (@typeInfo(Type) != .@"fn") {
                continue;
            }
            const function = @typeInfo(Type).@"fn";
            if (function.params.len == 0) {
                continue;
            }
            const first = function.params[0].type orelse continue;
            if (first == Owner or first == *Owner or first == *const Owner) {
                found = found ++ [1]Found{.{ .name = declaration.name, .owner = owner_name }};
            }
        }
        return found;
    }
}

// The function itself, for a `Found` of `Namespace`.
pub fn functionOf(comptime Namespace: type, comptime found: Found) @TypeOf(if (found.owner) |owner|
    @field(@field(Namespace, owner), found.name)
else
    @field(Namespace, found.name)) {
    if (found.owner) |owner| {
        return @field(@field(Namespace, owner), found.name);
    }
    return @field(Namespace, found.name);
}

test {
    _ = @import("functions.test.zig");
}
