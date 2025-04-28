//! RakNet Client Implementation in Zig
//! This module implements a client for the RakNet protocol, commonly used in Minecraft Bedrock Edition
//! and other games. It provides functionality for connecting to RakNet servers, handling packets,
//! and managing the client-server communication.

const std = @import("std");
const socket = @import("./socket/socket.zig");
const Cclient = @import("./client/client.zig");
const BinaryStream = @import("./binarystream/stream.zig").BinaryStream;
const Framer = @import("./client/framer.zig");
const UnconnectedPong = @import("./proto/unconnected_pong.zig");
const ServerInfo = @import("./proto/server_info.zig");

/// Global context instance used to maintain client state across the application
var global_context: ?*Context = null;

/// Context struct that holds the client instance and defines packet handling methods
pub const Context = struct {
    /// Reference to the RakNet client instance
    client: *Cclient.Client,

    /// Initialize a new Context with a client instance
    pub fn init(clientValue: *Cclient.Client) Context {
        return Context{ .client = clientValue };
    }

    /// Handle encapsulated (wrapped) packets received from the server
    fn handleEncapsulatedPacket(msg: []const u8) void {
        _ = msg;
        std.debug.print("Received encapsulated packet\n", .{});
    }

    /// Handle successful connection events
    /// Calculates and displays the connection time in milliseconds
    fn handleConnect(msg: []const u8) void {
        _ = msg;
        if (global_context) |ctx| {
            const time = std.time.milliTimestamp() - ctx.client.conTime;
            std.debug.print("Connected to server in {d}ms\n", .{time});
            std.debug.print("Client Con Time {d}\n", .{ctx.client.conTime});
            std.debug.print("Current Time {d}\n", .{std.time.milliTimestamp()});
        }
    }

    /// Handle dropped framesets (out-of-order packets)
    fn handleDropFrameset(msg: []const u8) void {
        _ = msg;
        std.debug.print("Dropped out of order frameset\n", .{});
    }

    /// Handle disconnection events
    /// Performs cleanup by deinitializing the client
    fn handleDisconnect(msg: []const u8) void {
        std.debug.print("Disconnect event received: {s}\n", .{msg});
        if (global_context) |ctx| {
            std.debug.print("Deiniting client\n", .{});
            ctx.client.deinit();
        }
    }

    /// Handle unconnected pong responses from the server
    /// Parses and displays detailed server information
    fn handleUnconnectedPong(msg: []const u8) void {
        const pong = UnconnectedPong.UnconnectedPong.deserialize(msg) catch unreachable;
        const info = ServerInfo.parseServerInfo(pong.message) catch unreachable;
        std.debug.print("\nServer Info:\n", .{});
        std.debug.print("  Type: {s}\n", .{info.type});
        std.debug.print("  Message: {s}\n", .{info.message});
        std.debug.print("  Protocol: {d}\n", .{info.protocol});
        std.debug.print("  Version: {s}\n", .{info.version});
        std.debug.print("  Players: {d}/{d}\n", .{ info.playerCount, info.maxPlayers });
        std.debug.print("  Server Name: {s}\n", .{info.serverName});
        std.debug.print("  Gamemode: {s}\n", .{info.gamemode});
        std.debug.print("  Server GUID: {d}\n", .{pong.server_guid});
    }
};

/// Main entry point for the RakNet client application
pub fn main() !void {
    std.debug.print("Starting Client...\n", .{});

    // Initialize the client with localhost address and default RakNet port
    var client = try Cclient.Client.init("127.0.0.1", 19132);
    defer client.deinit();

    // Set up the context and event handlers
    var ctx = Context.init(&client);
    global_context = &ctx;
    try client.emitter.on("connect", Context.handleConnect);
    try client.emitter.on("drop_frameset", Context.handleDropFrameset);
    try client.emitter.on("disconnect", Context.handleDisconnect);
    try client.emitter.on("encapsulated", Context.handleEncapsulatedPacket);
    try client.emitter.on("unconnected_pong", Context.handleUnconnectedPong);

    // Attempt to connect to the server
    client.connect() catch |err| {
        std.debug.print("Failed to connect: {any}\n", .{err});
        if (err == error.ConnectionTimeout) {
            std.debug.print("Connection timed out - is the server running?\n", .{});
        }
        return err;
    };

    // Main client loop - ticks every 50ms to process network events
    while (true) {
        std.time.sleep(50 * std.time.ns_per_ms);
        try client.tick();
    }
}

// Basic test demonstrating ArrayList functionality
test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
