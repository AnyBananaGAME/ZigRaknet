const binarystream = @import("../binarystream/stream.zig");
const std = @import("std");

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
        _ = try stream.skip(16); // Magic
        const guid = try stream.readI64(binarystream.Endianess.Big);
        const security = try stream.readBool();
        var cookies: u32 = 0;
        if(security) cookies = try stream.readU32(.Big);
        const mtu_size = try stream.readU16(binarystream.Endianess.Big);
        return OpenConnectionReplyOne{.guid = guid, .security = security, .mtu_size = mtu_size, .cookies = cookies };
    }
};