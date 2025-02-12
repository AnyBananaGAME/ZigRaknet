const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;

pub const ID: u8 = 0x09;
pub const ConnectionRequest = struct {
    guid: i64,
    timestamp: i64,
    security: bool,

    pub fn init(guid: i64, timestamp: i64, security: bool) ConnectionRequest {
        return ConnectionRequest{ .guid = guid, .timestamp = timestamp, .security = security };
    }

    pub fn serialize(self: ConnectionRequest) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        try stream.writeUint8(ID);
        try stream.writeI64(self.guid, .Big);
        try stream.writeI64(self.timestamp, .Big);
        try stream.writeBool(self.security);
        return try stream.getBytes();
    }
};
