const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const Magic = @import("../client/client.zig").MAGIC;
const std = @import("std");

pub const ID: u8 = 0x01;
pub const UnconnectedPing = struct {
    timestamp: i64,
    guid: i64,

    pub fn init(guid: i64) !UnconnectedPing {
        return UnconnectedPing{ .guid = guid, .timestamp = std.time.timestamp() };
    }

    pub fn serialize(self: *UnconnectedPing) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        try stream.writeUint8(ID);
        try stream.writeI64(self.timestamp, .Big);
        try stream.write(&Magic);
        try stream.writeI64(self.guid, .Big);
        return try stream.getBytes();
    }
};


