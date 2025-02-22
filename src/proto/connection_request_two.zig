const binarystream = @import("../binarystream/stream.zig");
const client = @import("../client/client.zig");
const Address = @import("../proto/types/address.zig").Address;

pub const ID = 0x07;
pub const OpenConnectionRequestTwo = struct { 
    address: Address,
    mtu_size: u16,
    guid: i64,
    // From Reply One
    cookie: ?u32,

    pub fn init(address: Address, mtu_size: u16, guid: i64, cookie: ?u32) OpenConnectionRequestTwo {
        return OpenConnectionRequestTwo { .address = address, .mtu_size = mtu_size, .guid = guid, .cookie = cookie };
    }

    pub fn serialize(self: *OpenConnectionRequestTwo) ![]const u8 {
        var stream = try binarystream.BinaryStream.init(null, 0); 
        try stream.writeUint8(ID);
        try stream.write(&client.MAGIC);
        if(self.cookie) |cookie| {
            try stream.writeU32(cookie, binarystream.Endianess.Big);
            try stream.writeBool(false); // No need to challenge anything
        }
        const data = try self.address.write();
        try stream.write(data);
        try stream.writeU16(self.mtu_size, binarystream.Endianess.Big);
        try stream.writeI64(self.guid, binarystream.Endianess.Big);
        return stream.getBytes();
    }
};