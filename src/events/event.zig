const std = @import("std");

const MAX_LISTENERS = 32;
const MAX_EVENT_NAME_LEN = 32;

const EventListener = struct {
    name: []const u8,
    name_hash: u64,
    once: bool,
    context: ?*anyopaque,
    cb: *const fn (ctx: *const anyopaque, message: []const u8) void,
    cleanup: ?*const fn (ctx: *anyopaque) void,
    next_free: ?usize, // Index of next free slot for our free list
};

pub const EventEmitter = struct {
    allocator: std.mem.Allocator,
    listeners: [MAX_LISTENERS]?EventListener,
    count: usize,
    mutex: std.Thread.RwLock, // Reader-writer lock for better concurrency
    debug: bool = false,
    first_free: ?usize = null, // Head of our free list
    event_map: std.StringHashMap(std.ArrayList(usize)), // Maps event names to listener indices

    pub fn init(allocator: std.mem.Allocator) EventEmitter {
        return EventEmitter{
            .allocator = allocator,
            .listeners = [_]?EventListener{null} ** MAX_LISTENERS,
            .count = 0,
            .mutex = std.Thread.RwLock{},
            .debug = false,
            .event_map = std.StringHashMap(std.ArrayList(usize)).init(allocator),
        };
    }

    pub fn initDefault() EventEmitter {
        return init(std.heap.page_allocator);
    }

    pub fn emit(self: *EventEmitter, event: []const u8, msg: []const u8) void {
        // Take a read lock since we're only reading listener data
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        if (self.debug) std.debug.print("Emitting event: {s} with message length: {d}\n", .{ event, msg.len });

        // Get all listeners for this event using our hashmap
        if (self.event_map.get(event)) |indices| {
            var to_remove = std.ArrayList(usize).init(self.allocator);
            defer to_remove.deinit();

            // First pass: Call all callbacks
            for (indices.items) |i| {
                if (self.listeners[i]) |*listener| {
                    listener.cb(listener.context orelse undefined, msg);
                    if (listener.once) {
                        to_remove.append(i) catch continue;
                    }
                }
            }

            // Second pass: Remove "once" listeners
            if (to_remove.items.len > 0) {
                // Need write lock for modifications
                self.mutex.unlock();
                self.mutex.lock();
                for (to_remove.items) |i| {
                    if (self.listeners[i]) |listener| {
                        if (listener.cleanup) |cleanup| {
                            cleanup(listener.context.?);
                        }
                        // Add to free list
                        self.listeners[i] = EventListener{
                            .name = "",
                            .name_hash = 0,
                            .once = false,
                            .context = null,
                            .cb = undefined,
                            .cleanup = null,
                            .next_free = self.first_free,
                        };
                        self.first_free = i;
                        self.count -= 1;

                        // Remove from event_map
                        if (self.event_map.getPtr(event)) |list| {
                            for (list.items, 0..) |idx, list_i| {
                                if (idx == i) {
                                    _ = list.swapRemove(list_i);
                                    break;
                                }
                            }
                        }
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

        // Use free list for O(1) slot allocation
        const idx = if (self.first_free) |free_idx| blk: {
            const next_free = self.listeners[free_idx].?.next_free;
            self.first_free = next_free;
            break :blk free_idx;
        } else blk: {
            // Find first null slot if no free list
            for (self.listeners, 0..) |listener, i| {
                if (listener == null) break :blk i;
            }
            return error.TooManyListeners; // Should not happen due to count check
        };

        // Store the event name and create a new listener
        const name_hash = std.hash.Wyhash.hash(0, event);
        self.listeners[idx] = EventListener{
            .name = event,
            .name_hash = name_hash,
            .cb = cb,
            .context = context,
            .cleanup = cleanup,
            .once = is_once,
            .next_free = null,
        };
        self.count += 1;

        // Add to event map
        var entry = try self.event_map.getOrPut(event);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(usize).init(self.allocator);
        }
        try entry.value_ptr.append(idx);
    }

    pub fn removeListener(self: *EventEmitter, event: []const u8, cb: *const fn (ctx: *const anyopaque, msg: []const u8) void) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.event_map.getPtr(event)) |indices| {
            var i: usize = 0;
            while (i < indices.items.len) {
                const idx = indices.items[i];
                if (self.listeners[idx]) |listener| {
                    if (listener.cb == cb) {
                        if (listener.cleanup) |cleanup| {
                            cleanup(listener.context.?);
                        }
                        // Add to free list
                        self.listeners[idx] = EventListener{
                            .name = "",
                            .name_hash = 0,
                            .once = false,
                            .context = null,
                            .cb = undefined,
                            .cleanup = null,
                            .next_free = self.first_free,
                        };
                        self.first_free = idx;
                        self.count -= 1;
                        _ = indices.swapRemove(i);
                        continue;
                    }
                }
                i += 1;
            }
        }
    }

    pub fn removeAllListeners(self: *EventEmitter, event: ?[]const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (event) |e| {
            if (self.event_map.getPtr(e)) |indices| {
                for (indices.items) |idx| {
                    if (self.listeners[idx]) |listener| {
                        if (listener.cleanup) |cleanup| {
                            cleanup(listener.context.?);
                        }
                    }
                    self.listeners[idx] = null;
                }
                self.count -= indices.items.len;
                indices.clearAndFree();
                _ = self.event_map.remove(e);
            }
        } else {
            // Clear all listeners
            for (self.listeners[0..]) |*listener| {
                if (listener.*) |l| {
                    if (l.cleanup) |cleanup| {
                        cleanup(l.context.?);
                    }
                }
                listener.* = null;
            }
            self.event_map.clearAndFree();
            self.count = 0;
            self.first_free = null;
        }
    }

    pub fn deinit(self: *EventEmitter) void {
        self.removeAllListeners(null);
        self.event_map.deinit();
    }
};
