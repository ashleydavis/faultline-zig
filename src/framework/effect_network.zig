// The simulated network. With no failure injected a name resolves to the loopback address, a
// connection opens to a server that never says anything (a read ends at once) and accepts every
// write and listening, binding and accepting all succeed. Nothing here reaches a real network.
//
// Every call that can fail asks the injector once, passing the failures that can happen to that
// call and returns what the row in `docs/FAILURES.md` says. Reads and writes are on sockets this
// module opened, so the rows that need a connection first (a reset part way through, a short
// response) happen at a read or write that comes after a connect, which is how a test sequences
// them. A handle this module did not hand out is passed to the `Io` underneath.

const std = @import("std");
const net = std.Io.net;
const state = @import("effect_state.zig");

// What a socket in the table is doing.
const Role = enum {
    // The slot is free.
    closed,
    // Opened by connect or accept: reads and writes work.
    connected,
    // Opened by listen: accept works.
    listening,
    // Opened by bind: only datagrams can be sent.
    bound,
};

// How many sockets can be open at once. Reaching it returns `error.ProcessFdQuotaExceeded`, as a
// process that has run out of descriptors would. Sixty-four is far more than a function under test
// opens at one time and keeps the table a fixed-size array.
const socket_capacity = 64;

// What each handle is doing, indexed by the handle minus `state.first_handle`.
var roles: [socket_capacity]Role = [_]Role{.closed} ** socket_capacity;

// The port a socket is given when its address asks for port zero (any port). The first of the
// range an operating system hands out as ephemeral ports.
const ephemeral_port: u16 = 49152;

// The partial response a "short response" failure delivers: the start of an HTTP response that
// stops before its body, so a parser that expects a length finds the stream ending early.
pub const short_response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial";

// The bytes a "response that does not parse" failure delivers: not what any text protocol
// allows, starting with bytes that are not valid text.
pub const unparseable_response = "\xff\xfe\x00\x01 this is not a protocol message";

// What a lookup, a connect, a listen or bind, an accept, a read, a write and a send can have
// happen to them. Each list is the rows of the Network table that call can return.
const lookup_kinds = state.kindsFor(.network, &.{ "name_does_not_resolve", "host_lookup_finds_no_address", "name_server_fails", "name_server_returns_a_bad_record", "network_down" });
const connect_kinds = state.kindsFor(.network, &.{ "connection_refused", "connection_times_out", "network_unreachable", "address_not_available", "network_down", "host_unreachable", "too_many_open_sockets" });
const listen_kinds = state.kindsFor(.network, &.{ "address_already_in_use_when_listening_or_binding", "address_not_available", "network_down", "too_many_open_sockets" });
const accept_kinds = state.kindsFor(.network, &.{ "connection_aborted_before_it_is_accepted", "network_down", "blocked_by_a_firewall", "too_many_open_sockets" });
const read_kinds = state.kindsFor(.network, &.{ "connection_reset_part_way_through", "short_response", "response_that_does_not_parse" });
const write_kinds = state.kindsFor(.network, &.{ "connection_reset_part_way_through", "send_on_a_socket_that_is_not_connected" });
const send_kinds = state.kindsFor(.network, &.{ "connection_reset_part_way_through", "message_too_large_to_send", "send_on_a_socket_that_is_not_connected" });
const write_file_kinds = state.kindsFor(.network, &.{"network_down"});
const local_kinds = state.kindsFor(.network, &.{"too_many_open_sockets"});

// Forgets every socket.
pub fn reset() void {
    roles = [_]Role{.closed} ** socket_capacity;
}

// Writes the network entries of the `Io` vtable into `room`.
pub fn override(room: *std.Io.VTable) void {
    room.netLookup = lookup;
    room.netConnectIp = connectIp;
    room.netListenIp = listenIp;
    room.netBindIp = bindIp;
    room.netAccept = accept;
    room.netConnectUnix = connectUnix;
    room.netListenUnix = listenUnix;
    room.netSocketCreatePair = socketCreatePair;
    room.netSend = send;
    room.netRead = read;
    room.netWrite = write;
    room.netWriteFile = writeFile;
    room.netClose = close;
    room.netShutdown = shutdown;
}

// How many sockets are open now.
pub fn countOpen() usize {
    var count: usize = 0;
    for (roles) |role| {
        if (role != .closed) {
            count += 1;
        }
    }
    return count;
}

// Whether `handle` is one this module handed out.
fn isMine(handle: net.Socket.Handle) bool {
    return handle >= state.first_handle and handle < state.first_handle + socket_capacity;
}

// The index in the table of a handle that is mine.
fn slotOf(handle: net.Socket.Handle) usize {
    return @intCast(handle - state.first_handle);
}

// Takes a free slot for a new socket in `role`. Returns `error.ProcessFdQuotaExceeded` when every
// slot is in use.
fn open(role: Role) error{ProcessFdQuotaExceeded}!net.Socket.Handle {
    for (&roles, 0..) |*slot, index| {
        if (slot.* == .closed) {
            slot.* = role;
            return state.first_handle + @as(i32, @intCast(index));
        }
    }
    return error.ProcessFdQuotaExceeded;
}

// The address a new socket reports: the one asked for, with a port when none was asked for.
fn addressOf(address: net.IpAddress) net.IpAddress {
    var result = address;
    switch (result) {
        .ip4 => |*ip4| {
            if (ip4.port == 0) {
                ip4.port = ephemeral_port;
            }
        },
        .ip6 => |*ip6| {
            if (ip6.port == 0) {
                ip6.port = ephemeral_port;
            }
        },
    }
    return result;
}

fn lookup(
    _: ?*anyopaque,
    host_name: net.HostName,
    resolved: *std.Io.Queue(net.HostName.LookupResult),
    options: net.HostName.LookupOptions,
) net.HostName.LookupError!void {
    // The real lookup closes the queue before it returns, success or not and callers rely on it
    // to know the answers have ended.
    defer resolved.close(state.own);
    const chosen = state.ask(.network, &lookup_kinds);
    if (chosen) |kind| {
        if (state.isKind(.network, "name_does_not_resolve", kind)) {
            return error.UnknownHostName;
        }
        if (state.isKind(.network, "host_lookup_finds_no_address", kind)) {
            return error.NoAddressReturned;
        }
        if (state.isKind(.network, "name_server_fails", kind)) {
            return error.NameServerFailure;
        }
        if (state.isKind(.network, "name_server_returns_a_bad_record", kind)) {
            return error.InvalidDnsARecord;
        }
        return error.NetworkDown;
    }
    const address: net.IpAddress = if (options.family == .ip6) .{ .ip6 = .loopback(options.port) } else .{ .ip4 = .loopback(options.port) };
    resolved.putOne(state.own, .{ .address = address }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => unreachable, // The queue is closed only by this function, on its way out.
    };
    if (options.canonical_name_buffer) |buffer| {
        const length = @min(host_name.bytes.len, buffer.len);
        @memcpy(buffer[0..length], host_name.bytes[0..length]);
        resolved.putOne(state.own, .{ .canonical_name = .{ .bytes = buffer[0..length] } }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => unreachable, // The queue is closed only by this function, on its way out.
        };
    }
}

fn connectIp(
    _: ?*anyopaque,
    address: *const net.IpAddress,
    _: net.IpAddress.ConnectOptions,
) net.IpAddress.ConnectError!net.Socket {
    if (state.ask(.network, &connect_kinds)) |kind| {
        if (state.isKind(.network, "connection_refused", kind)) {
            return error.ConnectionRefused;
        }
        if (state.isKind(.network, "connection_times_out", kind)) {
            return error.Timeout;
        }
        if (state.isKind(.network, "network_unreachable", kind)) {
            return error.NetworkUnreachable;
        }
        if (state.isKind(.network, "address_not_available", kind)) {
            return error.AddressUnavailable;
        }
        if (state.isKind(.network, "network_down", kind)) {
            return error.NetworkDown;
        }
        if (state.isKind(.network, "host_unreachable", kind)) {
            return error.HostUnreachable;
        }
        return error.ProcessFdQuotaExceeded;
    }
    return .{ .handle = try open(.connected), .address = addressOf(address.*) };
}

fn listenIp(
    _: ?*anyopaque,
    address: *const net.IpAddress,
    _: net.IpAddress.ListenOptions,
) net.IpAddress.ListenError!net.Socket {
    try failListenOrBind(net.IpAddress.ListenError);
    return .{ .handle = try open(.listening), .address = addressOf(address.*) };
}

fn bindIp(
    _: ?*anyopaque,
    address: *const net.IpAddress,
    _: net.IpAddress.BindOptions,
) net.IpAddress.BindError!net.Socket {
    try failListenOrBind(net.IpAddress.BindError);
    return .{ .handle = try open(.bound), .address = addressOf(address.*) };
}

// Asks the injector about a listen or a bind, once and returns the error of the row it chose. The
// two calls have the same rows, so they share this.
fn failListenOrBind(comptime Error: type) Error!void {
    if (state.ask(.network, &listen_kinds)) |kind| {
        if (state.isKind(.network, "address_already_in_use_when_listening_or_binding", kind)) {
            return error.AddressInUse;
        }
        if (state.isKind(.network, "address_not_available", kind)) {
            return error.AddressUnavailable;
        }
        if (state.isKind(.network, "network_down", kind)) {
            return error.NetworkDown;
        }
        return error.ProcessFdQuotaExceeded;
    }
}

fn accept(
    _: ?*anyopaque,
    server: net.Socket.Handle,
    options: net.Server.AcceptOptions,
) net.Server.AcceptError!net.Socket {
    if (!isMine(server)) {
        return state.underneath.vtable.netAccept(state.underneath.userdata, server, options);
    }
    if (state.ask(.network, &accept_kinds)) |kind| {
        if (state.isKind(.network, "connection_aborted_before_it_is_accepted", kind)) {
            return error.ConnectionAborted;
        }
        if (state.isKind(.network, "network_down", kind)) {
            return error.NetworkDown;
        }
        if (state.isKind(.network, "blocked_by_a_firewall", kind)) {
            return error.BlockedByFirewall;
        }
        return error.ProcessFdQuotaExceeded;
    }
    if (roles[slotOf(server)] != .listening) {
        return error.SocketNotListening;
    }
    return .{ .handle = try open(.connected), .address = .{ .ip4 = .loopback(ephemeral_port) } };
}

// A local (unix) socket has no network to fail, so the only failure that can happen to it is
// running out of descriptors.
fn openLocal() error{ProcessFdQuotaExceeded}!net.Socket.Handle {
    if (state.ask(.network, &local_kinds) != null) {
        return error.ProcessFdQuotaExceeded;
    }
    return open(.connected);
}

fn connectUnix(_: ?*anyopaque, _: *const net.UnixAddress) net.UnixAddress.ConnectError!net.Socket.Handle {
    return openLocal();
}

fn listenUnix(
    _: ?*anyopaque,
    _: *const net.UnixAddress,
    _: net.UnixAddress.ListenOptions,
) net.UnixAddress.ListenError!net.Socket.Handle {
    if (state.ask(.network, &local_kinds) != null) {
        return error.ProcessFdQuotaExceeded;
    }
    return open(.listening);
}

fn socketCreatePair(_: ?*anyopaque, _: net.Socket.CreatePairOptions) net.Socket.CreatePairError![2]net.Socket {
    if (state.ask(.network, &local_kinds) != null) {
        return error.ProcessFdQuotaExceeded;
    }
    const first = try open(.connected);
    const second = open(.connected) catch |err| {
        roles[slotOf(first)] = .closed;
        return err;
    };
    return .{
        .{ .handle = first, .address = .{ .ip4 = .loopback(0) } },
        .{ .handle = second, .address = .{ .ip4 = .loopback(0) } },
    };
}

fn send(
    _: ?*anyopaque,
    handle: net.Socket.Handle,
    messages: []net.OutgoingMessage,
    flags: net.SendFlags,
) struct { ?net.Socket.SendError, usize } {
    if (!isMine(handle)) {
        return state.underneath.vtable.netSend(state.underneath.userdata, handle, messages, flags);
    }
    if (state.ask(.network, &send_kinds)) |kind| {
        if (state.isKind(.network, "connection_reset_part_way_through", kind)) {
            return .{ error.ConnectionResetByPeer, 0 };
        }
        if (state.isKind(.network, "message_too_large_to_send", kind)) {
            return .{ error.MessageOversize, 0 };
        }
        return .{ error.SocketUnconnected, 0 };
    }
    return .{ null, messages.len };
}

fn read(_: ?*anyopaque, handle: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    if (!isMine(handle)) {
        return state.underneath.vtable.netRead(state.underneath.userdata, handle, data);
    }
    if (state.ask(.network, &read_kinds)) |kind| {
        if (state.isKind(.network, "connection_reset_part_way_through", kind)) {
            return error.ConnectionResetByPeer;
        }
        if (state.isKind(.network, "short_response", kind)) {
            return copyInto(data, short_response);
        }
        return copyInto(data, unparseable_response);
    }
    if (roles[slotOf(handle)] != .connected) {
        return error.SocketUnconnected;
    }
    return 0;
}

// Copies as much of `bytes` as fits into the buffers of a read, in order. Returns how many.
fn copyInto(data: [][]u8, bytes: []const u8) usize {
    var copied: usize = 0;
    for (data) |buffer| {
        const count = @min(buffer.len, bytes.len - copied);
        @memcpy(buffer[0..count], bytes[copied..][0..count]);
        copied += count;
    }
    return copied;
}

fn write(
    _: ?*anyopaque,
    handle: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    if (!isMine(handle)) {
        return state.underneath.vtable.netWrite(state.underneath.userdata, handle, header, data, splat);
    }
    if (state.ask(.network, &write_kinds)) |kind| {
        if (state.isKind(.network, "connection_reset_part_way_through", kind)) {
            return error.ConnectionResetByPeer;
        }
        return error.SocketUnconnected;
    }
    if (roles[slotOf(handle)] != .connected) {
        return error.SocketUnconnected;
    }
    var accepted: usize = header.len;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |bytes| {
            accepted += bytes.len;
        }
        accepted += data[data.len - 1].len * splat;
    }
    return accepted;
}

// Sending a file over a socket reads the file through its reader, which is the filesystem's work
// and counts the bytes as accepted. The one failure the call can return other than a cancellation
// is `error.NetworkDown`, which is also what a failed read of the file becomes.
fn writeFile(
    _: ?*anyopaque,
    handle: net.Socket.Handle,
    header: []const u8,
    reader: *std.Io.File.Reader,
    limit: std.Io.Limit,
) net.Stream.Writer.WriteFileError!usize {
    if (!isMine(handle)) {
        return state.underneath.vtable.netWriteFile(state.underneath.userdata, handle, header, reader, limit);
    }
    if (state.ask(.network, &write_file_kinds) != null) {
        return error.NetworkDown;
    }
    const consumed = reader.interface.discardShort(@intFromEnum(limit)) catch {
        return error.NetworkDown;
    };
    return header.len + consumed;
}

fn close(_: ?*anyopaque, handles: []const net.Socket.Handle) void {
    for (handles) |handle| {
        if (isMine(handle)) {
            roles[slotOf(handle)] = .closed;
        } else {
            state.underneath.vtable.netClose(state.underneath.userdata, (&handle)[0..1]);
        }
    }
}

fn shutdown(_: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    if (!isMine(handle)) {
        return state.underneath.vtable.netShutdown(state.underneath.userdata, handle, how);
    }
}

test {
    _ = @import("effect_network.test.zig");
}
