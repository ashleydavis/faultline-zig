// Tests for the simulated network: the working behaviour with no failure and every failure in the
// Network table returned from the call that can return it.

const std = @import("std");
const net = std.Io.net;
const testing = std.testing;
const network = @import("effect_network.zig");
const effect_testing = @import("effect_testing.zig");

const failAt = effect_testing.failAt;
const World = effect_testing.World;

const address: net.IpAddress = .{ .ip4 = .loopback(80) };

// Resolves a name and returns the first thing the lookup queued, or the error.
fn lookupName(world: *World, family: ?net.IpAddress.Family) !net.HostName.LookupResult {
    var storage: [4]net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&storage);
    const name = try net.HostName.init("example.test");
    try world.io.vtable.netLookup(world.io.userdata, name, &queue, .{ .port = 443, .family = family });
    return queue.getOneUncancelable(world.io);
}

fn readOnce(world: *World, socket: net.Socket, buffer: []u8) !usize {
    var buffers = [_][]u8{buffer};
    return world.io.vtable.netRead(world.io.userdata, socket.handle, &buffers);
}

fn writeOnce(world: *World, socket: net.Socket, bytes: []const u8) !usize {
    return world.io.vtable.netWrite(world.io.userdata, socket.handle, &.{}, &.{bytes}, 1);
}

test "a lookup with no failure returns the loopback address and closes the queue" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var storage: [4]net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&storage);
    const name = try net.HostName.init("example.test");
    var canonical: [net.HostName.max_len]u8 = undefined;
    try world.io.vtable.netLookup(world.io.userdata, name, &queue, .{ .port = 443, .canonical_name_buffer = &canonical });

    const first = try queue.getOneUncancelable(world.io);
    try testing.expect(first.address.ip4.bytes[0] == 127);
    try testing.expectEqual(@as(u16, 443), first.address.ip4.port);
    const second = try queue.getOneUncancelable(world.io);
    try testing.expectEqualStrings("example.test", second.canonical_name.bytes);
    try testing.expectError(error.Closed, queue.getOneUncancelable(world.io));
}

test "a lookup of an ip6 family returns the ip6 loopback" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const result = try lookupName(&world, .ip6);
    try testing.expect(result.address == .ip6);
}

test "a lookup returns error.UnknownHostName when the name does not resolve" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "name_does_not_resolve")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.UnknownHostName, lookupName(&world, null));
}

test "a lookup returns error.NoAddressReturned when the host has no address" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "host_lookup_finds_no_address")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NoAddressReturned, lookupName(&world, null));
}

test "a lookup returns error.NameServerFailure when the name server fails" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "name_server_fails")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NameServerFailure, lookupName(&world, null));
}

test "a lookup returns error.InvalidDnsARecord when the name server returns a bad record" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "name_server_returns_a_bad_record")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.InvalidDnsARecord, lookupName(&world, null));
}

test "a lookup returns error.NetworkDown when the network is down" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "network_down")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NetworkDown, lookupName(&world, null));
}

test "a failed lookup still closes the queue" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "name_does_not_resolve")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var storage: [4]net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&storage);
    const name = try net.HostName.init("example.test");
    try testing.expectError(error.UnknownHostName, world.io.vtable.netLookup(world.io.userdata, name, &queue, .{ .port = 80 }));
    try testing.expectError(error.Closed, queue.getOneUncancelable(world.io));
}

test "a connect with no failure returns a socket whose reads end at once and whose writes are accepted" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    try testing.expectEqual(@as(usize, 1), network.countOpen());

    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try readOnce(&world, stream.socket, &buffer));
    try testing.expectEqual(@as(usize, 5), try writeOnce(&world, stream.socket, "hello"));

    stream.close(world.io);
    try testing.expectEqual(@as(usize, 0), network.countOpen());
}

test "a write counts the header, every slice and the repeats of the last slice" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    const accepted = try world.io.vtable.netWrite(world.io.userdata, stream.socket.handle, "ab", &.{ "cd", "e" }, 3);
    try testing.expectEqual(@as(usize, 7), accepted);
}

test "a connect to port zero reports an ephemeral port" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const any_port: net.IpAddress = .{ .ip4 = .loopback(0) };
    const stream = try any_port.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    try testing.expect(stream.socket.address.ip4.port != 0);
}

test "a connect returns error.ConnectionRefused when the connection is refused" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "connection_refused")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.ConnectionRefused, address.connect(world.io, .{ .mode = .stream }));
    try testing.expectEqual(@as(usize, 0), network.countOpen());
}

test "a connect returns error.Timeout when the connection times out" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "connection_times_out")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.Timeout, address.connect(world.io, .{ .mode = .stream }));
}

test "a connect returns error.NetworkUnreachable when the network is unreachable" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "network_unreachable")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NetworkUnreachable, address.connect(world.io, .{ .mode = .stream }));
}

test "a connect returns error.AddressUnavailable when the address is not available" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "address_not_available")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.AddressUnavailable, address.connect(world.io, .{ .mode = .stream }));
}

test "a connect returns error.NetworkDown when the network is down" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "network_down")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NetworkDown, address.connect(world.io, .{ .mode = .stream }));
}

test "a connect returns error.HostUnreachable when the host is unreachable" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "host_unreachable")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.HostUnreachable, address.connect(world.io, .{ .mode = .stream }));
}

test "a connect returns error.ProcessFdQuotaExceeded when there are too many open sockets" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "too_many_open_sockets")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.ProcessFdQuotaExceeded, address.connect(world.io, .{ .mode = .stream }));
}

test "a connect returns error.ProcessFdQuotaExceeded when every slot is in use" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var opened: usize = 0;
    while (address.connect(world.io, .{ .mode = .stream })) |_| {
        opened += 1;
    } else |err| {
        try testing.expectEqual(error.ProcessFdQuotaExceeded, err);
    }
    try testing.expect(opened > 0);
    try testing.expectEqual(opened, network.countOpen());
}

test "a read after a connect returns error.ConnectionResetByPeer when the connection is reset" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "connection_reset_part_way_through")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var buffer: [16]u8 = undefined;
    try testing.expectError(error.ConnectionResetByPeer, readOnce(&world, stream.socket, &buffer));
}

test "a write after a connect returns error.ConnectionResetByPeer when the connection is reset" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 2, "connection_reset_part_way_through")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var buffer: [16]u8 = undefined;
    _ = try readOnce(&world, stream.socket, &buffer);
    try testing.expectError(error.ConnectionResetByPeer, writeOnce(&world, stream.socket, "hello"));
}

test "a read after a connect returns a response that ends before the expected length" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "short_response")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var buffer: [128]u8 = undefined;
    const count = try readOnce(&world, stream.socket, &buffer);
    try testing.expectEqualStrings(network.short_response, buffer[0..count]);
    // The response then ends: the next read, with no failure planned, returns nothing.
    try testing.expectEqual(@as(usize, 0), try readOnce(&world, stream.socket, &buffer));
}

test "a short response is cut off by a buffer that is smaller than it" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "short_response")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try readOnce(&world, stream.socket, &small));
    try testing.expectEqualStrings("HTTP", &small);
}

test "a read after a connect returns bytes that do not parse" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "response_that_does_not_parse")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var buffer: [128]u8 = undefined;
    const count = try readOnce(&world, stream.socket, &buffer);
    try testing.expectEqualStrings(network.unparseable_response, buffer[0..count]);
    try testing.expect(!std.unicode.utf8ValidateSlice(buffer[0..count]));
}

test "a listen with no failure returns a socket and accept returns a connected one" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    var server = try address.listen(world.io, .{});
    defer server.deinit(world.io);
    const stream = try server.accept(world.io);
    defer stream.close(world.io);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try readOnce(&world, stream.socket, &buffer));
}

test "a listen returns error.AddressInUse when the address is already in use" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "address_already_in_use_when_listening_or_binding")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.AddressInUse, address.listen(world.io, .{}));
}

test "a listen returns error.AddressUnavailable when the address is not available" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "address_not_available")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.AddressUnavailable, address.listen(world.io, .{}));
}

test "a listen returns error.NetworkDown when the network is down" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "network_down")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NetworkDown, address.listen(world.io, .{}));
}

test "a listen returns error.ProcessFdQuotaExceeded when there are too many open sockets" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "too_many_open_sockets")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.ProcessFdQuotaExceeded, address.listen(world.io, .{}));
}

test "a bind with no failure returns a socket" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const socket = try address.bind(world.io, .{ .mode = .dgram });
    defer socket.close(world.io);
    try testing.expectEqual(@as(usize, 1), network.countOpen());
}

test "a bind returns error.AddressInUse when the address is already in use" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "address_already_in_use_when_listening_or_binding")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.AddressInUse, address.bind(world.io, .{ .mode = .dgram }));
}

test "a bind returns error.AddressUnavailable when the address is not available" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "address_not_available")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.AddressUnavailable, address.bind(world.io, .{ .mode = .dgram }));
}

test "a bind returns error.NetworkDown when the network is down" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "network_down")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.NetworkDown, address.bind(world.io, .{ .mode = .dgram }));
}

test "a bind returns error.ProcessFdQuotaExceeded when there are too many open sockets" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 0, "too_many_open_sockets")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();
    try testing.expectError(error.ProcessFdQuotaExceeded, address.bind(world.io, .{ .mode = .dgram }));
}

test "an accept returns error.ConnectionAborted when the connection is aborted before it is accepted" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "connection_aborted_before_it_is_accepted")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var server = try address.listen(world.io, .{});
    defer server.deinit(world.io);
    try testing.expectError(error.ConnectionAborted, server.accept(world.io));
}

test "an accept returns error.NetworkDown when the network is down" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "network_down")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var server = try address.listen(world.io, .{});
    defer server.deinit(world.io);
    try testing.expectError(error.NetworkDown, server.accept(world.io));
}

test "an accept returns error.BlockedByFirewall when a firewall blocks it" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "blocked_by_a_firewall")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var server = try address.listen(world.io, .{});
    defer server.deinit(world.io);
    try testing.expectError(error.BlockedByFirewall, server.accept(world.io));
}

test "an accept returns error.ProcessFdQuotaExceeded when there are too many open sockets" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "too_many_open_sockets")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    var server = try address.listen(world.io, .{});
    defer server.deinit(world.io);
    try testing.expectError(error.ProcessFdQuotaExceeded, server.accept(world.io));
}

test "an accept on a socket that is not listening returns error.SocketNotListening" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    try testing.expectError(error.SocketNotListening, world.io.vtable.netAccept(world.io.userdata, stream.socket.handle, {}));
}

test "a write returns error.SocketUnconnected for a send on a socket that is not connected" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "send_on_a_socket_that_is_not_connected")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    try testing.expectError(error.SocketUnconnected, writeOnce(&world, stream.socket, "hello"));
}

test "a write on a bound socket that was never connected returns error.SocketUnconnected" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const socket = try address.bind(world.io, .{ .mode = .dgram });
    defer socket.close(world.io);
    try testing.expectError(error.SocketUnconnected, writeOnce(&world, socket, "hello"));
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.SocketUnconnected, readOnce(&world, socket, &buffer));
}

test "a datagram send with no failure is accepted" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const socket = try address.bind(world.io, .{ .mode = .dgram });
    defer socket.close(world.io);
    try socket.send(world.io, &address, "ping");
}

test "a datagram send returns error.MessageOversize when the message is too large to send" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "message_too_large_to_send")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const socket = try address.bind(world.io, .{ .mode = .dgram });
    defer socket.close(world.io);
    try testing.expectError(error.MessageOversize, socket.send(world.io, &address, "ping"));
}

test "a datagram send returns error.SocketUnconnected when the socket is not connected" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "send_on_a_socket_that_is_not_connected")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const socket = try address.bind(world.io, .{ .mode = .dgram });
    defer socket.close(world.io);
    try testing.expectError(error.SocketUnconnected, socket.send(world.io, &address, "ping"));
}

test "a datagram send returns error.ConnectionResetByPeer when the connection is reset" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "connection_reset_part_way_through")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const socket = try address.bind(world.io, .{ .mode = .dgram });
    defer socket.close(world.io);
    try testing.expectError(error.ConnectionResetByPeer, socket.send(world.io, &address, "ping"));
}

test "a local socket pair and a local connect and listen work and can run out of descriptors" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const pair = try world.io.vtable.netSocketCreatePair(world.io.userdata, .{});
    try testing.expectEqual(@as(usize, 2), network.countOpen());
    world.io.vtable.netClose(world.io.userdata, &.{ pair[0].handle, pair[1].handle });
    try testing.expectEqual(@as(usize, 0), network.countOpen());

    const path: net.UnixAddress = .{ .path = "/simulated.sock" };
    const listening = try world.io.vtable.netListenUnix(world.io.userdata, &path, .{});
    const connected = try world.io.vtable.netConnectUnix(world.io.userdata, &path);
    try testing.expectEqual(@as(usize, 2), network.countOpen());
    world.io.vtable.netClose(world.io.userdata, &.{ listening, connected });
}

test "local sockets return error.ProcessFdQuotaExceeded when there are too many open sockets" {
    const plan = [_]@import("injector.zig").Injection{
        failAt(.network, 0, "too_many_open_sockets"),
        failAt(.network, 1, "too_many_open_sockets"),
        failAt(.network, 2, "too_many_open_sockets"),
    };
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const path: net.UnixAddress = .{ .path = "/simulated.sock" };
    try testing.expectError(error.ProcessFdQuotaExceeded, world.io.vtable.netConnectUnix(world.io.userdata, &path));
    try testing.expectError(error.ProcessFdQuotaExceeded, world.io.vtable.netListenUnix(world.io.userdata, &path, .{}));
    try testing.expectError(error.ProcessFdQuotaExceeded, world.io.vtable.netSocketCreatePair(world.io.userdata, .{}));
}

test "a write of a file returns error.NetworkDown when the network is down" {
    const plan = [_]@import("injector.zig").Injection{failAt(.network, 1, "network_down")};
    var world: World = undefined;
    world.start(&plan);
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var reader: std.Io.File.Reader = undefined;
    try testing.expectError(error.NetworkDown, world.io.vtable.netWriteFile(world.io.userdata, stream.socket.handle, "", &reader, .unlimited));
}

test "every call asks the injector once and the places are numbered in order" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    const stream = try address.connect(world.io, .{ .mode = .stream });
    defer stream.close(world.io);
    var buffer: [4]u8 = undefined;
    _ = try readOnce(&world, stream.socket, &buffer);
    _ = try writeOnce(&world, stream.socket, "x");

    try testing.expectEqual(@as(usize, 3), world.injector.recorded.items.len);
    for (world.injector.recorded.items, 0..) |place, index| {
        try testing.expect(place.point.eql(.{ .effect = .network, .occurrence = @intCast(index) }));
    }
}

// What the stand-in for the real `Io` was asked, so a test can see that a handle that is not this
// module's was handed on.
var handed_on: u32 = 0;

fn standInShutdown(_: ?*anyopaque, _: net.Socket.Handle, _: net.ShutdownHow) net.ShutdownError!void {
    handed_on += 1;
}

fn standInClose(_: ?*anyopaque, _: []const net.Socket.Handle) void {
    handed_on += 1;
}

fn standInRead(_: ?*anyopaque, _: net.Socket.Handle, _: [][]u8) net.Stream.Reader.Error!usize {
    handed_on += 1;
    return 9;
}

test "a handle this module did not hand out goes to the Io underneath without asking the injector" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var stand_in_room = threaded.io().vtable.*;
    stand_in_room.netShutdown = standInShutdown;
    stand_in_room.netClose = standInClose;
    stand_in_room.netRead = standInRead;
    const stand_in: std.Io = .{ .userdata = threaded.io().userdata, .vtable = &stand_in_room };

    var injector = @import("injector.zig").Injector.init(testing.allocator, &.{});
    defer injector.deinit();
    defer @import("effect_state.zig").injector = null;
    var room: std.Io.VTable = undefined;
    const io = @import("world_effects.zig").install(stand_in, &room, &injector);

    handed_on = 0;
    try io.vtable.netShutdown(io.userdata, 5, .both);
    io.vtable.netClose(io.userdata, &.{5});
    var buffer: [4]u8 = undefined;
    var buffers = [_][]u8{&buffer};
    try testing.expectEqual(@as(usize, 9), try io.vtable.netRead(io.userdata, 5, &buffers));
    try testing.expectEqual(@as(u32, 3), handed_on);
    try testing.expectEqual(@as(usize, 0), injector.recorded.items.len);
}

test "reset forgets every socket" {
    var world: World = undefined;
    world.start(&.{});
    defer world.stop();

    _ = try address.connect(world.io, .{ .mode = .stream });
    try testing.expectEqual(@as(usize, 1), network.countOpen());
    network.reset();
    try testing.expectEqual(@as(usize, 0), network.countOpen());
}
