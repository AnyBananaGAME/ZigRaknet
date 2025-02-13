const std = @import("std");
const socket = @import("./socket/socket.zig");
const Cclient = @import("./client/client.zig");

pub fn main() !void {
    std.debug.print("Starting Client...\n", .{});
    var client = try Cclient.Client.init("127.0.0.1", 19132);
    defer client.deinit();
    try client.connect();
    while (true) {
        std.time.sleep(std.time.ns_per_s);
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit();
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
