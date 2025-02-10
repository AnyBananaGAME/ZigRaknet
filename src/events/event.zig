const std = @import("std");

const EventListener = struct {
    name: []const u8,
    once: bool,
    cb: *const fn (message: []const u8) void,
};

pub const EventEmitter = struct {
    allocator: std.mem.Allocator,
    listeners: std.ArrayList(EventListener),

    pub fn init(allocator: std.mem.Allocator) EventEmitter {
        return EventEmitter{ .allocator = allocator, .listeners = std.ArrayList(EventListener).init(allocator) };
    }

    pub fn initDefault() EventEmitter {
        return EventEmitter{
            .allocator = std.heap.page_allocator,
            .listeners = std.ArrayList(EventListener).init(std.heap.page_allocator),
        };
    }

    pub fn emit(self: *EventEmitter, event: []const u8, msg: []const u8) void {
        var idx: usize = 0;
        for (self.listeners.items) |listener| {
            if (eql(listener.name, event)) {
                listener.cb(msg);
                if (listener.once) {
                    _ = self.listeners.swapRemove(idx);
                }
            }
            idx = idx + 1;
        }
    }

    pub fn on(self: *EventEmitter, event: []const u8, cb: *const fn (message: []const u8) void) !void {
        try self.listeners.append(.{ .name = event, .cb = cb, .once = false });
    }

    pub fn once(self: *EventEmitter, event: []const u8, cb: *const fn (message: []const u8) void) !void {
        try self.listeners.append(.{ .name = event, .cb = cb, .once = true });
    }

    pub fn deinit(self: *EventEmitter) void {
        self.listeners.deinit();
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};
