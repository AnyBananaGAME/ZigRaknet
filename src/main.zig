const std = @import("std");
const socket = @import("./socket/socket.zig");
const Cclient = @import("./client/client.zig");

var global_context: ?*Context = null;

pub const Context = struct {
    client: *Cclient.Client,

    pub fn init(clientValue: *Cclient.Client) Context {
        return Context { .client = clientValue };
    }
        
    fn handleConnect(msg: []const u8) void {
        _ = msg;
        if (global_context) |ctx| {
            const time = std.time.milliTimestamp() - ctx.client.conTime;
            std.debug.print("Connected to server in {d}ms\n", .{time});
            std.debug.print("Client Con Time {d}\n", .{ctx.client.conTime});
            std.debug.print("Current Time {d}\n", .{std.time.milliTimestamp()});
        }
    }

    fn handleDropFrameset(msg: []const u8) void {
        _ = msg;
        std.debug.print("Dropped out of order frameset\n", .{});
    }
};

pub fn main() !void {
    std.debug.print("Starting Client...\n", .{});
    var client = try Cclient.Client.init("127.0.0.1", 19132);
    defer client.deinit();
    try client.connect();
    
    var ctx = Context.init(&client);
    global_context = &ctx;
    try client.emitter.on("connect", Context.handleConnect);
    try client.emitter.on("drop_frameset", Context.handleDropFrameset);

    while (true) {
        std.time.sleep(10 * std.time.ns_per_ms);
        try client.tick();
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
