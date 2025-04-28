const std = @import("std");

pub const DEBUG = false;

pub const TimingStats = struct {
    name: []const u8,
    start_time: i64,
    total_time: i64 = 0,
    calls: usize = 0,
    min_time: i64 = std.math.maxInt(i64),
    max_time: i64 = 0,

    pub fn init(name: []const u8) TimingStats {
        return TimingStats{
            .name = name,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn end(self: *TimingStats) void {
        if (!DEBUG) return;

        const end_time = std.time.milliTimestamp();
        const duration = end_time - self.start_time;
        self.total_time += duration;
        self.calls += 1;
        self.min_time = @min(self.min_time, duration);
        self.max_time = @max(self.max_time, duration);
    }

    pub fn print(self: *const TimingStats) void {
        if (!DEBUG) return;

        if (self.calls > 0) {
            const avg = @divFloor(self.total_time, @as(i64, @intCast(self.calls)));
            std.debug.print("[TIMING] {s}: calls={d} total={d}ms avg={d}ms min={d}ms max={d}ms\n", .{ self.name, self.calls, self.total_time, avg, self.min_time, self.max_time });
        }
    }
};

pub const TimingMap = struct {
    stats: std.StringHashMap(TimingStats),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TimingMap {
        return TimingMap{
            .stats = std.StringHashMap(TimingStats).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn start(self: *TimingMap, name: []const u8) !void {
        if (!DEBUG) return;

        const stats = TimingStats.init(name);
        try self.stats.put(name, stats);
    }

    pub fn end(self: *TimingMap, name: []const u8) void {
        if (!DEBUG) return;

        if (self.stats.getPtr(name)) |stats| {
            stats.end();
        }
    }

    pub fn printAll(self: *const TimingMap) void {
        if (!DEBUG) return;

        std.debug.print("\n=== Performance Statistics ===\n", .{});
        var it = self.stats.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.print();
        }
        std.debug.print("===========================\n\n", .{});
    }

    pub fn deinit(self: *TimingMap) void {
        self.stats.deinit();
    }
};
