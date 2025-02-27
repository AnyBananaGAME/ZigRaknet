const std = @import("std");
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;

pub const ID: u8 = 0x00;
pub const ConnectedPing = struct {
    timestamp: i64,

    pub fn init() ConnectedPing {
        const timestamp = std.time.timestamp();
        return ConnectedPing{ .timestamp = timestamp };
    }

    pub fn serialize(self: *ConnectedPing) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        try stream.writeUint8(ID);
        try stream.writeI64(self.timestamp, .Big);
        return try stream.getBytes();
    }

    pub fn deserialize(msg: []const u8) !ConnectedPing {
        var stream = try BinaryStream.init(msg, 0);
        _ = try stream.readUint8();
        const timestamp = try stream.readI64(.Big);
        return ConnectedPing{ .timestamp = timestamp };
    }
};
