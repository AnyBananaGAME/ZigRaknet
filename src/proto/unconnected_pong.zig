const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;

pub const ID: u8 = 0x1c;
pub const UnconnectedPong = struct { 
    server_timestamp: i64, 
    server_guid: i64,
    message: []const u8,

    pub fn init() !UnconnectedPong {
        return UnconnectedPong{};
    }

    pub fn deserialize(data: []const u8) !UnconnectedPong {
        var stream = try BinaryStream.init(data, 0);
        _ = try stream.readUint8(); // ID
        const server_timestamp = try stream.readI64(.Big);
        const server_guid = try stream.readI64(.Big);
        _ = try stream.skip(16); // Magic
        const message = try stream.readString16(.Big);
        return UnconnectedPong{ .server_timestamp = server_timestamp, .server_guid = server_guid, .message = message };
    }

    pub fn serialize(self: *UnconnectedPong) ![]const u8 {
        _ = self; // autofix
    }
};
