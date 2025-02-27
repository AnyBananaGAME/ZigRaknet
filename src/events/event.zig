const std = @import("std");

const MAX_LISTENERS = 32;
const MAX_EVENT_NAME_LEN = 32;

const EventListener = struct {
    name: []const u8,
    once: bool,
    context: ?*anyopaque,
    cb: *const fn (ctx: *const anyopaque, message: []const u8) void,
    cleanup: ?*const fn (ctx: *anyopaque) void,
};

pub const EventEmitter = struct {
    allocator: std.mem.Allocator,
    listeners: [MAX_LISTENERS]?EventListener,
    count: usize,
    mutex: std.Thread.Mutex,
    debug: bool = false,

    pub fn init(allocator: std.mem.Allocator) EventEmitter {
        return EventEmitter{
            .allocator = allocator,
            .listeners = [_]?EventListener{null} ** MAX_LISTENERS,
            .count = 0,
            .mutex = std.Thread.Mutex{},
            .debug = false,
        };
    }

    pub fn initDefault() EventEmitter {
        return EventEmitter{
            .allocator = std.heap.page_allocator,
            .listeners = [_]?EventListener{null} ** MAX_LISTENERS,
            .count = 0,
            .mutex = std.Thread.Mutex{},
            .debug = false,
        };
    }

    pub fn emit(self: *EventEmitter, event: []const u8, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.debug) std.debug.print("Emitting event: {s} with message length: {d}\n", .{event, msg.len});
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.listeners[i]) |*listener| {
                if (eql(listener.name, event)) {
                    if (self.debug) std.debug.print("Found matching listener for event: {s}\n", .{event});
                    listener.cb(listener.context orelse undefined, msg);
                    if (listener.once) {
                        if (listener.cleanup) |cleanup| {
                            cleanup(listener.context.?);
                        }
                        if (i < self.count - 1) {
                            self.listeners[i] = self.listeners[self.count - 1];
                        }
                        self.listeners[self.count - 1] = null;
                        self.count -= 1;
                        i -= 1;
                    }
                }
            }
        }
        if (self.debug) std.debug.print("Finished emitting event: {s}\n", .{event});
    }

    pub fn on(self: *EventEmitter, event: []const u8, comptime cb: anytype) !void {
        const Closure = struct {
            pub fn wrap(_: *const anyopaque, msg: []const u8) void {
                cb(msg);
            }
        };
        try self.addListener(event, null, &Closure.wrap, null, false);
    }

    pub fn onWithContext(self: *EventEmitter, event: []const u8, context: *anyopaque, cb: *const fn (ctx: *const anyopaque, msg: []const u8) void, cleanup: ?*const fn (ctx: *anyopaque) void) !void {
        try self.addListener(event, context, cb, cleanup, false);
    }

    pub fn once(self: *EventEmitter, event: []const u8, comptime cb: anytype) !void {
        const Closure = struct {
            pub fn wrap(_: *const anyopaque, msg: []const u8) void {
                cb(msg);
            }
        };
        try self.addListener(event, null, &Closure.wrap, null, true);
    }

    fn addListener(self: *EventEmitter, event: []const u8, context: ?*anyopaque, cb: *const fn (ctx: *const anyopaque, msg: []const u8) void, cleanup: ?*const fn (ctx: *anyopaque) void, is_once: bool) !void {
        if (event.len > MAX_EVENT_NAME_LEN) {
            return error.EventNameTooLong;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.count >= MAX_LISTENERS) {
            return error.TooManyListeners;
        }

        for (self.listeners[0..MAX_LISTENERS], 0..) |listener, i| {
            if (listener == null) {
                self.listeners[i] = EventListener{
                    .name = event,
                    .cb = cb,
                    .context = context,
                    .cleanup = cleanup,
                    .once = is_once,
                };
                self.count += 1;
                return;
            }
        }
    }

    pub fn removeListener(self: *EventEmitter, event: []const u8, cb: *const fn (ctx: *const anyopaque, msg: []const u8) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.listeners[i]) |listener| {
                if (eql(listener.name, event) and listener.cb == cb) {
                    if (listener.cleanup) |cleanup| {
                        cleanup(listener.context.?);
                    }
                    if (i < self.count - 1) {
                        self.listeners[i] = self.listeners[self.count - 1];
                    }
                    self.listeners[self.count - 1] = null;
                    self.count -= 1;
                    break;
                }
            }
        }
    }

    pub fn removeAllListeners(self: *EventEmitter, event: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (event) |e| {
            var i: usize = 0;
            while (i < self.count) {
                if (self.listeners[i]) |listener| {
                    if (eql(listener.name, e)) {
                        if (listener.cleanup) |cleanup| {
                            cleanup(listener.context.?);
                        }
                        if (i < self.count - 1) {
                            self.listeners[i] = self.listeners[self.count - 1];
                        }
                        self.listeners[self.count - 1] = null;
                        self.count -= 1;
                        continue;
                    }
                }
                i += 1;
            }
        } else {
            for (self.listeners[0..self.count]) |*listener| {
                if (listener.*) |l| {
                    if (l.cleanup) |cleanup| {
                        cleanup(l.context.?);
                    }
                }
                listener.* = null;
            }
            self.count = 0;
        }
    }

    pub fn deinit(self: *EventEmitter) void {
        self.removeAllListeners(null);
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};
