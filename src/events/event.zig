const std = @import("std");

const MAX_LISTENERS = 32;
const MAX_EVENT_NAME_LEN = 32;

const EventListener = struct {
    name: []const u8,
    once: bool,
    cb: *const fn (message: []const u8) void,
};

pub const EventEmitter = struct {
    allocator: std.mem.Allocator,
    listeners: [MAX_LISTENERS]?EventListener,
    count: usize,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) EventEmitter {
        return EventEmitter{
            .allocator = allocator,
            .listeners = [_]?EventListener{null} ** MAX_LISTENERS,
            .count = 0,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn initDefault() EventEmitter {
        return EventEmitter{
            .allocator = std.heap.page_allocator,
            .listeners = [_]?EventListener{null} ** MAX_LISTENERS,
            .count = 0,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn emit(self: *EventEmitter, event: []const u8, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.listeners[i]) |*listener| {
                if (eql(listener.name, event)) {
                    listener.cb(msg);
                    if (listener.once) {
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
    }

    pub fn on(self: *EventEmitter, event: []const u8, comptime cb: anytype) !void {
        const Closure = struct {
            pub fn wrap(msg: []const u8) void {
                cb(msg);
            }
        };
        try self.addListener(event, &Closure.wrap, false);
    }

    pub fn once(self: *EventEmitter, event: []const u8, comptime cb: anytype) !void {
        const Closure = struct {
            pub fn wrap(msg: []const u8) void {
                cb(msg);
            }
        };
        try self.addListener(event, &Closure.wrap, true);
    }

    fn addListener(self: *EventEmitter, event: []const u8, cb: *const fn (message: []const u8) void, is_once: bool) !void {
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
                    .once = is_once,
                };
                self.count += 1;
                return;
            }
        }
    }

    pub fn removeListener(self: *EventEmitter, event: []const u8, cb: *const fn (message: []const u8) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.listeners[i]) |listener| {
                if (eql(listener.name, event) and listener.cb == cb) {
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
