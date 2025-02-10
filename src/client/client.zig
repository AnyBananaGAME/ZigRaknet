const socket = @import("../socket/socket.zig");
const std = @import("std");
const stream = @import("../binarystream/stream.zig");
const reqOne = @import("../proto/connection_request_one.zig");
const repOne = @import("../proto/connection_reply_one.zig");

pub const MAGIC: [16]u8 = [16]u8{
    0x00, 0xff, 0xff, 0x00, 0xfe, 0xfe, 0xfe, 0xfe,
    0xfd, 0xfd, 0xfd, 0xfd, 0x12, 0x34, 0x56, 0x78,
};
pub const UDP_HEADER_SIZE: u16 = 28;
pub const MTU_SIZES = [_]u16{ 1492, 1200, 576 };

pub const Client = struct {
    socket: socket.Socket,
    host: []const u8,
    port: u16,
    mtu_size: u16 = 1492,
    guid: i64,

    pub fn init(host: []const u8, port: u16) !Client {
        const sock = try socket.Socket.init("0.0.0.0", 0);
        var rng = std.rand.DefaultPrng.init(std.time.nanoTimestamp());
        const random_generator = rng.random();

        return Client{
            .host = host,
            .port = port,
            .socket = sock,
            .guid = random_generator.int(i64),
        };
    }

    pub fn connect(self: *Client) !void {
        try self.socket.bind();
        self.socket.log();
        
        const MessageHandler = struct {
            var client: ?*Client = null;
            pub fn handler(msg: []const u8) void {
                if (client) |c| {
                    c.handleMessage(msg) catch |err| {
                        std.debug.print("Error handling message: {any}\n", .{err});
                    };
                }
            }
        };
        
        MessageHandler.client = self;
        try self.socket.emitter.on("message", MessageHandler.handler);
        
        if (!self.socket.isReady()) {
            return error.SocketNotReady;
        }
        try self.sendRequest();
    }

    pub fn handleMessage(self: *Client, msg: []const u8) !void {
        _ = self; // autofix
        std.debug.print("Received Packet {any}\n", .{msg[0]});
        if(msg[0] == repOne.ID) {
            const data = try repOne.OpenConnectionReplyOne.deserialize(msg);
            std.debug.print("Received OpenConnectionReplyOne with guid {any} and mtu {any}\n", .{ data.guid, data.mtu_size });
        }
    }

    pub fn deinit(self: *Client) void {
        self.socket.deinit();
    }

    pub fn send(self: *Client, data: []const u8) !void {
        std.debug.print("Client sending {d} bytes to {s}:{d}\n", .{ data.len, self.host, self.port });
        try self.socket.send(data, self.host, self.port);
    }

    pub fn sendRequest(self: *Client) !void {
        var packet = reqOne.OpenConnectionRequestOne.init(self.mtu_size);
        const data = try packet.serialize();
        try self.send(data);
    }
};
