const std = @import("std");
const socket = @import("./socket/socket.zig");
const Cclient = @import("./client/client.zig");
const BinaryStream = @import("./binarystream/stream.zig").BinaryStream;
const Framer = @import("./client/framer.zig");
const UnconnectedPong = @import("./proto/unconnected_pong.zig");
const ServerInfo = @import("./proto/server_info.zig");

var global_context: ?*Context = null;

pub const Context = struct {
    client: *Cclient.Client,

    pub fn init(clientValue: *Cclient.Client) Context {
        return Context { .client = clientValue };
    }
        
    fn handleEncapsulatedPacket(msg: []const u8) void {
        _ = msg;
        std.debug.print("Received encapsulated packet\n", .{});
    }

    fn handleConnect(msg: []const u8) void {
        _ = msg; // autofix
        // std.debug.print("Connection event received: {s}\n", .{msg});
        if (global_context) |ctx| {
            const time = std.time.milliTimestamp() - ctx.client.conTime;
            std.debug.print("Connected to server in {d}ms\n", .{time});
            // std.debug.print("Client Con Time {d}\n", .{ctx.client.conTime});
            // std.debug.print("Current Time {d}\n", .{std.time.milliTimestamp()});
            
            // Keep debug enabled to see what's happening after connection
            // ctx.client.debug = false;
        }
    }

    fn handleDropFrameset(msg: []const u8) void {
        _ = msg;
        std.debug.print("Dropped out of order frameset\n", .{});
    }

    fn handleDisconnect(msg: []const u8) void {
        std.debug.print("Disconnect event received: {s}\n", .{msg});
        if (global_context) |ctx| {
            std.debug.print("Deiniting client\n", .{});
            ctx.client.deinit();
        }
    }

    fn handleUnconnectedPong(msg: []const u8) void {
        const pong = UnconnectedPong.UnconnectedPong.deserialize(msg) catch unreachable;
        const info = ServerInfo.parseServerInfo(pong.message) catch unreachable;
        std.debug.print("\nServer Info:\n", .{});
        std.debug.print("  Type: {s}\n", .{info.type});
        std.debug.print("  Message: {s}\n", .{info.message});
        std.debug.print("  Protocol: {d}\n", .{info.protocol});
        std.debug.print("  Version: {s}\n", .{info.version});
        std.debug.print("  Players: {d}/{d}\n", .{info.playerCount, info.maxPlayers});
        std.debug.print("  Server Name: {s}\n", .{info.serverName});
        std.debug.print("  Gamemode: {s}\n", .{info.gamemode});
        std.debug.print("  Server GUID: {d}\n", .{pong.server_guid});    
    }
};

pub fn main() !void {
    std.debug.print("Starting Client...\n", .{});
    
    var client = try Cclient.Client.init("127.0.0.1", 19132);
    defer client.deinit();
    
    var ctx = Context.init(&client);
    global_context = &ctx;
    try client.emitter.on("connect", Context.handleConnect);
    try client.emitter.on("drop_frameset", Context.handleDropFrameset);
    try client.emitter.on("disconnect", Context.handleDisconnect);
    try client.emitter.on("encapsulated", Context.handleEncapsulatedPacket);
    try client.emitter.on("unconnected_pong", Context.handleUnconnectedPong);

    client.connect() catch |err| {
        std.debug.print("Failed to connect: {any}\n", .{err});
        if (err == error.ConnectionTimeout) {
            std.debug.print("Connection timed out - is the server running?\n", .{});
        }
        return err;
    };
    
    while (true) {
        std.time.sleep(50 * std.time.ns_per_ms);
        try client.tick();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
