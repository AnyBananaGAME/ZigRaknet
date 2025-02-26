const std = @import("std");
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;

pub const ID: u8 = 0x01;
pub const ConnectedPong = struct {
    timestamp: i64,
    pong_timestamp: i64,

    pub fn init(timestamp: i64) ConnectedPong {
        return ConnectedPong{ .timestamp = timestamp, .pong_timestamp = std.time.milliTimestamp() };
    }

    pub fn serialize(self: *ConnectedPong) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        try stream.writeUint8(ID);
        try stream.writeI64(self.timestamp, .Big);
        try stream.writeI64(self.pong_timestamp, .Big);
        return try stream.getBytes();
    }

    pub fn deserialize(msg: []const u8) !ConnectedPong {
        var stream = try BinaryStream.init(msg, 0);
        _ = try stream.readUint8();
        const timestamp = try stream.readI64(.Big);
        const pong_timestamp = try stream.readI64(.Big);
        return ConnectedPong{ .timestamp = timestamp, .pong_timestamp = pong_timestamp };
    }
};
