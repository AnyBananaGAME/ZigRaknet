const binarystream = @import("../binarystream/stream.zig");
const client = @import("../client/client.zig");

pub const ID = 0x05;
pub const OpenConnectionRequestOne = struct {
    mtu_size: u16,

    pub fn init (mtu_size: u16) OpenConnectionRequestOne {
        return OpenConnectionRequestOne { .mtu_size = mtu_size };
    }

    pub fn serialize(self: *OpenConnectionRequestOne) ![]const u8 {
        var stream = try binarystream.BinaryStream.init(null, 0); 
        try stream.writeUint8(ID);
        try stream.write(&client.MAGIC);
        try stream.writeUint8(11);

        const current_size = @as(u16, @intCast(stream.binary.items.len));
        const padding_size = self.mtu_size - client.UDP_HEADER_SIZE - current_size;
        
        var i: usize = 0;
        while (i < padding_size) : (i += 1) {
            try stream.writeUint8(0);
        }
        return stream.binary.items;
    }
};