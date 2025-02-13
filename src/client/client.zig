const socket = @import("../socket/socket.zig");
const std = @import("std");
const stream = @import("../binarystream/stream.zig");
const Framer = @import("./framer.zig").Framer;

const Address = @import("../proto//types/address.zig").Address;
const reqOne = @import("../proto/connection_request_one.zig");
const repOne = @import("../proto/connection_reply_one.zig");
const reqTwo = @import("../proto/connection_request_two.zig");
const repTwo = @import("../proto/connection_reply_two.zig");
const frameSet = @import("../proto/frameset.zig");

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
    framer: ?Framer,
    debug: bool = false,
    conTime: i64,

    pub fn init(host: []const u8, port: u16) !Client {
        const sock = try socket.Socket.init("0.0.0.0", 0);
        const result = @as(u64, @intCast(std.time.timestamp()));
        var rng = std.rand.DefaultPrng.init(result);
        var random = rng.random();
        return Client{ .host = host, .conTime = undefined, .debug = false, .port = port, .socket = sock, .guid = random.int(i64), .framer = null };
    }

    pub fn connect(self: *Client) !void {
        try self.socket.bind();
        // self.socket.log();
        self.framer = try Framer.init(self);
        self.conTime = std.time.milliTimestamp();
        if (self.debug) std.debug.print("Using custom GUID {any}\n", .{self.guid});

        const MessageHandler = struct {
            var client: ?*Client = null;
            pub fn handler(msg: []const u8) void {
                if (client) |c| {
                    c.handleMessage(msg) catch |err| {
                        // no need for debug.
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
        if (self.debug) std.debug.print("Received Packet {any}\n", .{msg[0]});
        switch (msg[0]) {
            repOne.ID => {
                const data = try repOne.OpenConnectionReplyOne.deserialize(msg);
                if (self.debug) std.debug.print("Received OpenConnectionReplyOne with\n - guid {any}\n - mtu {any}\n - security {any}\n", .{ data.guid, data.mtu_size, data.security });
                const address = Address.init(self.host, self.port, 4);
                var req = reqTwo.OpenConnectionRequestTwo.init(address, data.mtu_size, self.guid);
                const ser = try req.serialize();
                try self.send(ser);
            },
            repTwo.ID => {
                const data = try repTwo.OpenConnectionReplyTwo.deserialize(msg);
                if (self.debug) std.debug.print("Received OpenConnectionReplyTwo with\n - address  \n  - version {any}\n  - address {any}\n  - port {any} \n - guid {any}\n - mtu {any}\n - enncryption {any}\n", .{ data.address.version, data.address.address, data.address.port, data.guid, data.mtu_size, data.encryption_enabled });
                self.mtu_size = data.mtu_size;
                try self.framer.?.sendConnection();
            },
            frameSet.ID => {
                try self.framer.?.handleMessage(msg);
            },
            else => {
                std.debug.print("Received Unknown Packet {any}\n", .{msg[0]});
            },
        }
    }

    pub fn deinit(self: *Client) void {
        self.socket.deinit();
    }

    pub fn send(self: *Client, data: []const u8) !void {
        if (self.debug) std.debug.print("Client sending {d} bytes to {s}:{d}\n", .{ data.len, self.host, self.port });
        try self.socket.send(data, self.host, self.port);
    }

    pub fn sendRequest(self: *Client) !void {
        var packet = reqOne.OpenConnectionRequestOne.init(self.mtu_size);
        const data = try packet.serialize();
        try self.send(data);
    }
};
