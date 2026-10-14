// A function that connects, with the branch it takes when the connection fails. Faultline makes the
// connection fail, so no scenario is written for that branch.

const std = @import("std");

// Opens a connection and says whether it got one. Faultline builds the address from its type.
pub fn reachable(io: std.Io, address: std.Io.net.IpAddress) bool {
    var stream = address.connect(io, .{ .mode = .stream }) catch {
        return false;
    };
    stream.close(io);
    return true;
}
