//! UDP Socket Implementation for RakNet
//! This module provides a non-blocking UDP socket implementation with adaptive polling,
//! buffer pooling, and event-based message handling. It is designed to be efficient
//! for game networking, particularly for RakNet protocol communication.

const std = @import("std");
const net = std.net;
const os = std.os;
const posix = std.posix;
const emitter = @import("../events/event.zig");
const windows = std.os.windows;

/// Configuration options for socket behavior and performance tuning
pub const SocketConfig = struct {
    /// Minimum time between polling attempts (50 microseconds)
    min_poll_interval_ns: u64 = 50_000,

    /// Maximum time between polling attempts (500 microseconds)
    max_poll_interval_ns: u64 = 500_000,

    /// Number of packets to process in a single batch
    batch_size: u32 = 64,

    /// Size of individual packet buffers
    buffer_size: u32 = 2048,

    /// Number of pre-allocated packet buffers in the pool
    buffer_pool_size: u32 = 32,

    /// Whether to use adaptive polling intervals based on traffic
    adaptive_polling: bool = true,

    /// Multiplier for increasing poll interval during low activity
    backoff_multiplier: f32 = 1.5,

    /// Number of idle cycles before increasing poll interval
    activity_threshold: u32 = 8,

    /// Time threshold for considering the socket idle (1ms)
    idle_threshold_ns: u64 = 1_000_000,
};

/// Main Socket implementation with buffer pooling and adaptive polling
pub const Socket = struct {
    /// Node in the buffer pool linked list
    const BufferNode = struct {
        data: []u8,
        next: ?*BufferNode,
    };

    host: []const u8,
    port: u16,
    socket: posix.socket_t,
    emitter: emitter.EventEmitter,
    thread: ?std.Thread,
    running: std.atomic.Value(bool),
    ready: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    config: SocketConfig,
    buffer_pool: ?*BufferNode,
    pool_mutex: std.Thread.Mutex,
    last_poll_time: u64 = 0,
    current_poll_interval: u64 = 0,
    idle_count: u32 = 0,

    /// Initialize a new UDP socket with the given host, port, and configuration
    pub fn init(host: []const u8, port: u16, config: SocketConfig) !Socket {
        const allocator = std.heap.page_allocator;
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(sock);

        // Enable address reuse to prevent "address already in use" errors
        const yes: i32 = 1;
        _ = std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&yes)) catch |err| {
            std.debug.print("Warning: Failed to set SO_REUSEADDR: {}\n", .{err});
        };

        // Bind to specified host:port or use 0.0.0.0:0 for automatic port assignment
        const bind_addr = if (port == 0)
            try std.net.Address.parseIp4("0.0.0.0", 0)
        else
            try std.net.Address.parseIp4(host, port);

        try std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen());

        var socket = Socket{
            .host = host,
            .port = port,
            .socket = sock,
            .emitter = emitter.EventEmitter.init(allocator),
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .ready = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .config = config,
            .buffer_pool = null,
            .pool_mutex = std.Thread.Mutex{},
        };

        try socket.initBufferPool();
        return socket;
    }

    /// Initialize the buffer pool with pre-allocated packet buffers
    fn initBufferPool(self: *Socket) !void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        var i: usize = 0;
        while (i < self.config.buffer_pool_size) : (i += 1) {
            var node = try self.allocator.create(BufferNode);
            node.data = try self.allocator.alloc(u8, self.config.buffer_size);
            node.next = self.buffer_pool;
            self.buffer_pool = node;
        }
    }

    /// Get a buffer from the pool for packet reception
    fn getBuffer(self: *Socket) ?*BufferNode {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        if (self.buffer_pool) |node| {
            self.buffer_pool = node.next;
            node.next = null;
            return node;
        }
        return null;
    }

    /// Return a buffer to the pool after use
    fn returnBuffer(self: *Socket, node: *BufferNode) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        node.next = self.buffer_pool;
        self.buffer_pool = node;
    }

    /// Start the socket's listening thread
    pub fn bind(self: *Socket) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, listen, .{self});
        self.ready.store(true, .release);
    }

    /// Main listening loop that processes incoming packets
    fn listen(self: *Socket) !void {
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        var current_interval: u64 = 0;

        // Set up non-blocking mode for Windows or POSIX systems
        if (@import("builtin").os.tag == .windows) {
            var mode: c_ulong = 1;
            if (windows.ws2_32.ioctlsocket(self.socket, windows.ws2_32.FIONBIO, &mode) != 0) {
                return error.SetSocketNonBlockingFailed;
            }
        } else {
            const flags = try posix.fcntl(self.socket, posix.F.GETFL, 0);
            _ = try posix.fcntl(self.socket, posix.F.SETFL, flags | posix.O.NONBLOCK);
        }

        while (self.running.load(.acquire)) {
            var packets_processed: usize = 0;
            const batch_start = std.time.nanoTimestamp();

            // Process packets in batches for efficiency
            while (packets_processed < self.config.batch_size) {
                const buffer_node = self.getBuffer() orelse break;
                const received_bytes = std.posix.recvfrom(
                    self.socket,
                    buffer_node.data,
                    0,
                    &addr,
                    &addr_len,
                ) catch |err| {
                    self.returnBuffer(buffer_node);
                    if (err == error.WouldBlock) break;
                    continue;
                };

                if (received_bytes > 0) {
                    packets_processed += 1;
                    current_interval = 0; // Reset backoff on successful receive
                    self.emitter.emit("message", buffer_node.data[0..received_bytes]);
                }
                self.returnBuffer(buffer_node);
            }

            // Implement adaptive polling based on packet activity
            if (packets_processed == 0) {
                // Use exponential backoff up to max_poll_interval when idle
                current_interval = if (current_interval == 0)
                    self.config.min_poll_interval_ns
                else
                    @min(current_interval * 2, self.config.max_poll_interval_ns);
                std.time.sleep(current_interval);
            } else {
                // Add small pause if batch processing was quick
                const batch_duration = std.time.nanoTimestamp() - batch_start;
                if (batch_duration < 1_000_000) { // If batch took less than 1ms
                    std.time.sleep(100_000); // Small 100μs pause to prevent CPU spinning
                }
            }
        }
    }

    /// Check if the socket is ready for communication
    pub fn isReady(self: *Socket) bool {
        return self.ready.load(.acquire);
    }

    /// Send data to a specific host and port
    pub fn send(self: *Socket, data: []const u8, host: []const u8, port: u16) !void {
        if (!self.isReady()) return error.SocketNotReady;

        const target_addr = try std.net.Address.parseIp4(host, port);
        _ = try std.posix.sendto(
            self.socket,
            data,
            0,
            &target_addr.any,
            target_addr.getOsSockLen(),
        );
    }

    /// Clean up socket resources and stop the listening thread
    pub fn deinit(self: *Socket) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);
            if (self.thread) |thread| thread.join();
        }

        // Clean up buffer pool
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        while (self.buffer_pool) |node| {
            self.buffer_pool = node.next;
            self.allocator.free(node.data);
            self.allocator.destroy(node);
        }

        _ = std.posix.shutdown(self.socket, std.posix.ShutdownHow.recv) catch {};
    }

    /// Log socket binding information
    pub fn log(self: *Socket) void {
        std.debug.print("Socket bound to {s}:{}\n", .{ self.host, self.port });
    }

    /// Poll for new packets with adaptive polling interval
    pub fn poll(self: *Socket) !void {
        const start_time = std.time.nanoTimestamp();

        // Implement adaptive polling delay
        if (self.config.adaptive_polling) {
            const elapsed = @as(u64, @intCast(start_time - self.last_poll_time));
            if (elapsed < self.current_poll_interval) {
                const sleep_time = self.current_poll_interval - elapsed;
                if (sleep_time > 1000) { // Only sleep if more than 1 microsecond
                    std.time.sleep(sleep_time);
                }
            }
        }

        var packets_processed: u32 = 0;
        var buffer: [2048]u8 = undefined;

        // Process packets in batches for efficiency
        while (packets_processed < self.config.batch_size) {
            const result = try self.socket.receive(&buffer);
            if (result == null) break;

            const packet = result.?;
            try self.handlePacket(packet.data[0..packet.size]);
            packets_processed += 1;
        }

        // Adjust polling interval based on activity level
        if (self.config.adaptive_polling) {
            if (packets_processed > 0) {
                // High activity - use minimum polling interval
                self.current_poll_interval = self.config.min_poll_interval_ns;
                self.idle_count = 0;
            } else {
                // No activity - gradually increase polling interval
                self.idle_count += 1;
                if (self.idle_count > self.config.activity_threshold) {
                    const new_interval = @as(f32, @floatFromInt(self.current_poll_interval)) * self.config.backoff_multiplier;
                    self.current_poll_interval = @min(@as(u64, @intFromFloat(new_interval)), self.config.max_poll_interval_ns);
                }
            }
        }

        self.last_poll_time = start_time;
    }
};
