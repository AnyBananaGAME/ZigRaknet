const std = @import("std");
const net = std.net;
const posix = std.posix;
const emitter = @import("../events/event.zig");

const MessageQueue = struct {
    const Message = struct {
        data: []u8,
        len: usize,
    };

    allocator: std.mem.Allocator,
    queue: std.ArrayList(Message),
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) MessageQueue {
        return .{
            .allocator = allocator,
            .queue = std.ArrayList(Message).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    fn push(self: *MessageQueue, data: []const u8) !void {
        const msg_buffer = try self.allocator.alloc(u8, data.len);
        @memcpy(msg_buffer, data);

        const msg = Message{
            .data = msg_buffer,
            .len = data.len,
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(msg);
    }

    fn pop(self: *MessageQueue) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.queue.items.len > 0) self.queue.orderedRemove(0) else null;
    }

    fn deinit(self: *MessageQueue) void {
        while (self.pop()) |msg| {
            self.allocator.free(msg.data);
        }
        self.queue.deinit();
    }
};

const BufferPool = struct {
    const Buffer = []u8;
    const BUFFER_SIZE = 2048; // Optimized for typical UDP packet size
    const POOL_SIZE = 32; // Number of pre-allocated buffers

    allocator: std.mem.Allocator,
    available: std.ArrayList(Buffer),
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) !BufferPool {
        var pool = BufferPool{
            .allocator = allocator,
            .available = std.ArrayList(Buffer).init(allocator),
            .mutex = std.Thread.Mutex{},
        };

        var i: usize = 0;
        while (i < POOL_SIZE) : (i += 1) {
            const buf = try allocator.alloc(u8, BUFFER_SIZE);
            try pool.available.append(buf);
        }
        return pool;
    }

    fn acquire(self: *BufferPool) ?Buffer {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.available.items.len > 0)
            self.available.orderedRemove(0)
        else
            null;
    }

    fn release(self: *BufferPool, buffer: Buffer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.available.append(buffer);
    }

    fn deinit(self: *BufferPool) void {
        for (self.available.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.available.deinit();
    }
};

pub const Socket = struct {
    host: []const u8,
    port: u16,
    socket: posix.socket_t,
    emitter: emitter.EventEmitter,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    ready: std.atomic.Value(bool),
    msg_queue: MessageQueue,
    buffer_pool: BufferPool,
    process_thread: ?std.Thread,
    allocator: std.mem.Allocator,

    const Config = struct {
        batch_size: usize = 32,
        process_delay_ns: u64 = 100_000,
        recv_timeout_ms: u32 = 25,
    };

    pub fn init(host: []const u8, port: u16) !Socket {
        const allocator = std.heap.c_allocator;
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(sock);

        const yes: i32 = 1;
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&yes)) catch |err| {
            std.debug.print("Warning: Failed to set SO_REUSEADDR: {}\n", .{err});
        };

        const rcvbuf_size: i32 = 262144; // 256KB
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&rcvbuf_size)) catch |err| {
            std.debug.print("Warning: Failed to set SO_RCVBUF: {}\n", .{err});
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
            .msg_queue = MessageQueue.init(allocator),
            .buffer_pool = try BufferPool.init(allocator),
            .process_thread = null,
            .allocator = allocator,
        };
    }

    pub fn bind(self: *Socket) !void {
        if (self.running.load(.acquire)) {
            return;
        }
        self.running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, listen, .{self});

        self.process_thread = try std.Thread.spawn(.{}, processMessages, .{self});

        std.time.sleep(1 * std.time.ns_per_ms);
        self.ready.store(true, .release);
    }

    fn listen(self: *Socket) !void {
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        var backoff_delay: u64 = 1 * std.time.ns_per_ms;
        const max_backoff: u64 = 100 * std.time.ns_per_ms;

        while (self.running.load(.acquire)) {
            if (self.buffer_pool.acquire()) |buffer| {
                const received_bytes = std.posix.recvfrom(
                    self.socket,
                    buffer[0..],
                    0,
                    &addr,
                    &addr_len,
                ) catch |err| {
                    try self.buffer_pool.release(buffer);

                    if (err == error.WouldBlock) {
                        std.time.sleep(1 * std.time.ns_per_ms);
                        continue;
                    }
                    if (err == error.ConnectionResetByPeer) continue;

                    std.debug.print("Listen error: {}\n", .{err});
                    std.time.sleep(backoff_delay);
                    backoff_delay = @min(backoff_delay * 2, max_backoff);
                    continue;
                };

                backoff_delay = 5 * std.time.ns_per_ms;
                try self.msg_queue.push(buffer[0..received_bytes]);
                try self.buffer_pool.release(buffer);
            } else {
                std.time.sleep(5 * std.time.ns_per_ms);
            }
        }
    }

    fn processMessages(self: *Socket) !void {
        const config = Config{};
        var batch_count: usize = 0;

        while (self.running.load(.acquire)) {
            while (batch_count < config.batch_size) : (batch_count += 1) {
                if (self.msg_queue.pop()) |msg| {
                    self.emitter.emit("message", msg.data);
                    self.allocator.free(msg.data);
                } else break;
            }

            if (batch_count > 0) {
                batch_count = 0;
            } else {
                std.time.sleep(config.process_delay_ns);
            }
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

        const sent_bytes = try std.posix.sendto(self.socket, data, 0, &target_addr.any, target_addr.getOsSockLen());
        if (sent_bytes != data.len) {
            std.debug.print("Incomplete write: sent {d} of {d} bytes\n", .{ sent_bytes, data.len });
            return error.IncompleteWrite;
        }
    }

    pub fn deinit(self: *Socket) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);
            if (self.thread) |thread| thread.join();
            if (self.process_thread) |thread| thread.join();
        }
        _ = std.posix.shutdown(self.socket, std.posix.ShutdownHow.recv) catch {};
        self.msg_queue.deinit();
        self.buffer_pool.deinit();
    }

    pub fn log(self: *Socket) void {
        std.debug.print("Socket binded to {s} {any}.\n", .{ self.host, self.port });
    }
};
