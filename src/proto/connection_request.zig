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
        // Pre-calculate required size: ID(1) + guid(8) + timestamp(8) + security(1)
        const required_size = 18;
        var stream = try BinaryStream.initCapacity(null, required_size);
        try stream.writeUint8(ID);
        try stream.writeI64(self.guid, .Big);
        try stream.writeI64(self.timestamp, .Big);
        try stream.writeBool(self.security);
        return try stream.getBytes();
    }
};
