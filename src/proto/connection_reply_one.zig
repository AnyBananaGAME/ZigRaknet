const binarystream = @import("../binarystream/stream.zig");

pub const ID = 0x06;
pub const OpenConnectionReplyOne = struct {
    guid: i64,
    security: bool,
    cookies: ?u32,
    mtu_size: u16,

    pub fn init (guid: i64, security: bool, mtu_size: u16) !OpenConnectionReplyOne {
        return OpenConnectionReplyOne { .mtu_size = mtu_size, .guid = guid, .security = security };
    }

    pub fn deserialize(data: []const u8) !OpenConnectionReplyOne {
        var stream = try binarystream.BinaryStream.init(data, 0); 
        _ = try stream.readUint8(); // ID
        _ = try stream.read(16); // Magic
        const guid = try stream.readI64(binarystream.Endianess.Big);
        const security = try stream.readBool();
        // if(self.security) self.cookies = self.readU32();
        const mtu_size = try stream.readU16(binarystream.Endianess.Big);
        return OpenConnectionReplyOne{.guid = guid, .security = security, .mtu_size = mtu_size, .cookies = null };
    }
};