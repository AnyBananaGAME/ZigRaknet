const socket = @import("../socket/socket.zig");
const std = @import("std");
const stream = @import("../binarystream/stream.zig");
const Framer = @import("./framer.zig").Framer;
const Emitter = @import("../events/event.zig").EventEmitter;

const Address = @import("../proto/types/address.zig").Address;
const reqOne = @import("../proto/connection_request_one.zig");
const repOne = @import("../proto/connection_reply_one.zig");
const reqTwo = @import("../proto/connection_request_two.zig");
const repTwo = @import("../proto/connection_reply_two.zig");
const frameSet = @import("../proto/frameset.zig");
const Ack = @import("../proto/ack.zig");
const UnconnectedPing = @import("../proto/unconnected_ping.zig").UnconnectedPing;
const UnconnectedPong = @import("../proto/unconnected_pong.zig");

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
    connected: bool = false,
    buffer_pool: std.ArrayList([]u8),
    emitter: Emitter,

    pub fn init(host: []const u8, port: u16) !Client {
        const sock = try socket.Socket.init("0.0.0.0", 0);
        const result = @as(u64, @intCast(std.time.timestamp()));
        var rng = std.rand.DefaultPrng.init(result);
        var random = rng.random();
        var buffer_pool = std.ArrayList([]u8).init(std.heap.page_allocator);
        try buffer_pool.append(try std.heap.page_allocator.alloc(u8, 1500));
        try buffer_pool.append(try std.heap.page_allocator.alloc(u8, 576));
        return Client{ 
            .host = host, 
            .connected = false, 
            .conTime = undefined, 
            .debug = false, 
            .port = port, 
            .socket = sock, 
            .guid = random.int(i64), 
            .framer = null,
            .buffer_pool = buffer_pool,
            .emitter = Emitter.init(std.heap.page_allocator),
        };
    }

    pub fn tick(self: *Client) !void {
        if (self.framer == null) return;
        try self.framer.?.tick();
    }

    pub fn sendPing(self: *Client) !void {
        var ping = try UnconnectedPing.init(self.guid);
        const data = try ping.serialize();
        if (self.debug) std.debug.print("Sending Unconnected Ping\n", .{});
        try self.send(data);
    }

    pub fn connect(self: *Client) !void {
        const startTime = std.time.milliTimestamp();
        self.framer = try Framer.init(self);
        
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

        try self.socket.bind();
        self.conTime = std.time.milliTimestamp();

        if (!self.socket.isReady()) {
            return error.SocketNotReady;
        }

        try self.sendPing();
        const endTime = std.time.milliTimestamp();
        if (self.debug) std.debug.print("Connect Function Took {any}ms\n", .{endTime - startTime});
    }

    pub fn handleMessage(self: *Client, msg: []const u8) !void {
        if (self.debug) std.debug.print("Received Packet {any}\n", .{msg[0]});
        var id = msg[0];
        if(id & 0xf0 == 0x80) id = 0x80;
        
        switch (id) {
            repOne.ID => {
                const data = try repOne.OpenConnectionReplyOne.deserialize(msg);
                const address = Address.init(self.host, self.port, 4);
                var cookie: ?u32 = null;
                if(data.security) cookie = data.cookies.?;
                var req = reqTwo.OpenConnectionRequestTwo.init(address, data.mtu_size, self.guid, cookie);
                const ser = try req.serialize();
                const oneTime = std.time.milliTimestamp();
                if (self.debug) std.debug.print("Received OpenConnectionReplyOne with\n - guid {any}\n - mtu {any}\n - security {any}\nTook {any}ms\n", .{ data.guid, data.mtu_size, data.security, oneTime - self.conTime });
                try self.send(ser);
            },
            repTwo.ID => {
                const data = try repTwo.OpenConnectionReplyTwo.deserialize(msg);
                const twoTime = std.time.milliTimestamp();
                self.mtu_size = data.mtu_size;
                try self.framer.?.sendConnection();
                if (self.debug) std.debug.print("Received OpenConnectionReplyTwo with\n - address  \n  - version {any}\n  - address {any}\n  - port {any} \n - guid {any}\n - mtu {any}\n - enncryption {any}\nTook {any}ms\n", .{ data.address.version, data.address.address, data.address.port, data.guid, data.mtu_size, data.encryption_enabled, twoTime - self.conTime });
            },
            frameSet.ID => {
                const framerStart = std.time.milliTimestamp();
                if (self.debug) std.debug.print("Received FrameSet in {d}ms\n", .{framerStart - self.conTime});
                try self.framer.?.handleMessage(msg);
            },
            Ack.ID => {
                try self.framer.?.onAck(try Ack.Ack.deserialize(msg));
            },
            UnconnectedPong.ID => {
                if (self.debug) std.debug.print("Received Unconnected Pong\n", .{});
                const pong = try UnconnectedPong.UnconnectedPong.deserialize(msg);
                if (self.debug) std.debug.print("Received Unconnected Pong with\n - server_timestamp {any}\n - server_guid {any}\n - message {any}\n", .{ pong.server_timestamp, pong.server_guid, pong.message });
                try self.sendRequest();
            },
            else => {
                if (self.debug) std.debug.print("Received Unknown Packet {any}\n", .{msg[0]});
            },
        }
    }

    pub fn deinit(self: *Client) void {
        for (self.buffer_pool.items) |buffer| {
            std.heap.page_allocator.free(buffer);
        }
        self.buffer_pool.deinit();
        self.socket.deinit();
    }

    fn getBuffer(self: *Client, size: usize) ![]u8 {
        for (self.buffer_pool.items) |buffer| {
            if (buffer.len >= size) {
                return buffer[0..size];
            }
        }
        const new_buffer = try std.heap.page_allocator.alloc(u8, size);
        try self.buffer_pool.append(new_buffer);
        return new_buffer;
    }

    pub fn send(self: *Client, data: []const u8) !void {
        const sendTime = std.time.milliTimestamp();
        if (self.debug) std.debug.print("Client sending {d} bytes to {s}:{d}\n", .{ data.len, self.host, self.port });
        const buffer = try self.getBuffer(data.len);
        @memcpy(buffer[0..data.len], data);
        try self.socket.send(buffer[0..data.len], self.host, self.port);
        const endTime = std.time.milliTimestamp();
        if (self.debug) std.debug.print("Send Function Took {any}ms\n", .{endTime - sendTime});
    }

    pub fn sendRequest(self: *Client) !void {
        var packet = reqOne.OpenConnectionRequestOne.init(self.mtu_size);
        const data = try packet.serialize();
        try self.send(data);
    }
};
