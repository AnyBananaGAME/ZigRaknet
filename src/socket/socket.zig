const std = @import("std");
const net = std.net;
const posix = std.posix;
const emitter = @import("../events/event.zig");

pub const Socket = struct {
    const BUFFER_SIZE: usize = 8000;
    const TICK_INTERVAL_NS: u64 = 2 * std.time.ns_per_ms; 
    
    host: []const u8,
    port: u16,
    socket: posix.socket_t,
    emitter: emitter.EventEmitter,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    ready: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    pub fn init(host: []const u8, port: u16) !Socket {
        const allocator = std.heap.c_allocator;
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(sock);

        const yes: i32 = 1;
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&yes)) catch |err| {
            std.debug.print("Warning: Failed to set SO_REUSEADDR: {}\n", .{err});
        };

        const buf_size: i32 = BUFFER_SIZE;
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&buf_size)) catch |err| {
            std.debug.print("Warning: Failed to set SO_RCVBUF: {}\n", .{err});
        };
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&buf_size)) catch |err| {
            std.debug.print("Warning: Failed to set SO_SNDBUF: {}\n", .{err});
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
            .allocator = allocator,
        };
    }

    pub fn bind(self: *Socket) !void {
        if (self.running.load(.acquire)) return;
        
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, listen, .{self});
        self.ready.store(true, .release);
    }

    fn listen(self: *Socket) !void {
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        var buffer = try self.allocator.alloc(u8, BUFFER_SIZE);
        defer self.allocator.free(buffer);

        while (self.running.load(.acquire)) {
            const received_bytes = std.posix.recvfrom(
                self.socket,
                buffer[0..],
                0,
                &addr,
                &addr_len,
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    std.time.sleep(TICK_INTERVAL_NS);
                    continue;
                },
                error.ConnectionResetByPeer => continue,
                else => {
                    std.debug.print("Listen error: {}\n", .{err});
                    continue;
                },
            };

            if (received_bytes > 0) {
                var msg_buffer = self.allocator.alloc(u8, received_bytes) catch continue;
                @memcpy(msg_buffer[0..received_bytes], buffer[0..received_bytes]);
                self.emitter.emit("message", msg_buffer);
            }
        }
    }

    pub fn isReady(self: *Socket) bool {
        return self.ready.load(.acquire);
    }

    pub fn send(self: *Socket, data: []const u8, host: []const u8, port: u16) !void {
        if (!self.isReady()) return error.SocketNotReady;

        const target_addr = try std.net.Address.parseIp4(host, port);
        var remaining = data.len;
        var offset: usize = 0;

        while (remaining > 0) {
            const sent_bytes = std.posix.sendto(
                self.socket,
                data[offset..],
                0,
                &target_addr.any,
                target_addr.getOsSockLen(),
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    std.time.sleep(TICK_INTERVAL_NS);
                    continue;
                },
                else => return err,
            };

            remaining -= sent_bytes;
            offset += sent_bytes;
        }
    }

    pub fn deinit(self: *Socket) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);
            if (self.thread) |thread| thread.join();
        }
        _ = std.posix.shutdown(self.socket, std.posix.ShutdownHow.recv) catch {};
    }

    pub fn log(self: *Socket) void {
        std.debug.print("Socket bound to {s}:{}\n", .{ self.host, self.port });
    }
};
