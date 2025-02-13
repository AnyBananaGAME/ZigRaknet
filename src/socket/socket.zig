const std = @import("std");
const net = std.net;
const posix = std.posix;
const emitter = @import("../events/event.zig");

pub const Socket = struct {
    host: []const u8,
    port: u16,
    socket: posix.socket_t,
    emitter: emitter.EventEmitter,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    ready: std.atomic.Value(bool),

    pub fn init(host: []const u8, port: u16) !Socket {
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(sock);

        const yes: i32 = 1;
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&yes)) catch |err| {
            std.debug.print("Warning: Failed to set SO_REUSEADDR: {}\n", .{err});
        };
        const bind_addr = if (port == 0)
            try std.net.Address.parseIp4("0.0.0.0", 0)
        else
            try std.net.Address.parseIp4(host, port);

        try std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

        return Socket{
            .host = host,
            .port = port,
            .socket = sock,
            .emitter = emitter.EventEmitter.initDefault(),
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .ready = std.atomic.Value(bool).init(false),
        };
    }

    pub fn bind(self: *Socket) !void {
        if (self.running.load(.acquire)) {
            return; // Already running
        }
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, listen, .{self});
        std.time.sleep(50 * std.time.ns_per_ms);
        self.ready.store(true, .release);
    }

    fn listen(self: *Socket) !void {
        var buffer: [1400]u8 = undefined;
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        while (self.running.load(.acquire)) {
            const received_bytes = std.posix.recvfrom(
                self.socket,
                buffer[0..],
                0,
                &addr,
                &addr_len,
            ) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.ConnectionResetByPeer) continue;
                std.debug.print("Listen error: {}\n", .{err});
                return err;
            };

            self.emitter.emit("message", buffer[0..received_bytes]);
        }
    }

    pub fn isReady(self: *Socket) bool {
        return self.ready.load(.acquire);
    }

    pub fn send(self: *Socket, data: []const u8, host: []const u8, port: u16) !void {
        if (!self.isReady()) {
            return error.SocketNotReady;
        }
        const target_addr = try std.net.Address.parseIp4(host, port);

        // std.debug.print("Sending {d} bytes to {s}:{d}\n", .{data.len, self.host, self.port});
        const sent_bytes = try std.posix.sendto(self.socket, data, 0, &target_addr.any, target_addr.getOsSockLen());
        if (sent_bytes != data.len) {
            std.debug.print("Incomplete write: sent {d} of {d} bytes\n", .{ sent_bytes, data.len });
            return error.IncompleteWrite;
        }
        // std.debug.print("Successfully sent {d} bytes\n", .{sent_bytes});
    }

    pub fn deinit(self: *Socket) void {
        if (self.thread != null) {
            self.running.store(false, .release);
            self.thread.?.join();
        }
        _ = std.posix.shutdown(self.socket, std.posix.ShutdownHow.recv) catch {};
    }

    pub fn log(self: *Socket) void {
        std.debug.print("Socket binded to {s} {any}.\n", .{ self.host, self.port });
    }
};
