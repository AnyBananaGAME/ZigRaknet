const binarystream = @import("../binarystream/stream.zig");
const Address = @import("../proto/types/address.zig").Address;

pub const ID = 0x08;
pub const OpenConnectionReplyTwo = struct {
    guid: i64,
    address: Address,
    mtu_size: u16,
    encryption_enabled: bool,

    pub fn init(address: Address, mtu_size: u16, guid: i64, encryption_enabled: bool) OpenConnectionReplyTwo {
        return OpenConnectionReplyTwo{
            .mtu_size = mtu_size,
            .address = address,
            .guid = guid,
            .encryption_enabled = encryption_enabled,
        };
    }

    pub fn deserialize(data: []const u8) !OpenConnectionReplyTwo {
        var stream = try binarystream.BinaryStream.init(data, 0);
        _ = try stream.readUint8(); // ID
        _ = try stream.skip(16); // Magic
        const guid = try stream.readI64(binarystream.Endianess.Big);
        const address = try Address.read(&stream);
        const mtu_size = try stream.readU16(binarystream.Endianess.Big);
        const encryption_enabled = try stream.readBool();
        return OpenConnectionReplyTwo{
            .guid = guid,
            .address = address,
            .mtu_size = mtu_size,
            .encryption_enabled = encryption_enabled,
        };
    }
};
