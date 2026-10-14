// A function that makes a symlink in the simulated filesystem and follows it.

const std = @import("std");

// What `follow` found at the end of the link.
pub const Found = enum { the_target, nothing_there, could_not_link };

// Makes `link_name` point at `target_name` and reads the first byte through the link. A link whose
// target is missing is a dangling link, which has its own code path.
pub fn follow(io: std.Io, target_name: []const u8, link_name: []const u8) Found {
    const directory = std.Io.Dir.cwd();
    directory.symLink(io, target_name, link_name, .{}) catch {
        return .could_not_link;
    };
    var buffer: [4]u8 = undefined;
    const contents = directory.readFile(io, link_name, &buffer) catch {
        return .nothing_there;
    };
    _ = contents;
    return .the_target;
}
