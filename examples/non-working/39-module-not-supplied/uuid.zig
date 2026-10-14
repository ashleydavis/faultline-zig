// Code that imports a module the project's build never registered.

const shortid = @import("shortid");

// A new identifier.
pub fn nextId() []const u8 {
    return shortid.generate();
}
