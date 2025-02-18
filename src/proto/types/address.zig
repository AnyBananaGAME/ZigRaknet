const binarystream = @import("../../binarystream/stream.zig");
const std = @import("std");

pub const AddressErrors = error{
    InvalidIPv4Address,
};

pub const Address = struct {
    address: []const u8,
    port: u16,
    version: u8,

    pub fn init(address: []const u8, port: u16, version: u8) Address {
        return Address{
            .address = address,
            .port = port,
            .version = version,
        };
    }

    pub fn write(self: Address) ![]const u8 {
        var stream = try binarystream.BinaryStream.init(null, 0);
        try stream.writeUint8(self.version);
        if (self.version == 4) {
            var parts = std.mem.tokenize(u8, self.address, ".");
            var part_count: usize = 0;
            while (parts.next()) |part| {
                part_count += 1;
                const b = try std.fmt.parseInt(u8, part, 10);
                try stream.writeUint8((~b) & 0xff);
            }
            if (part_count != 4) {
                return AddressErrors.InvalidIPv4Address;
            }
            try stream.writeU16(self.port, .Big);
        }
        // TODO: Implement IPv6
        return stream.getBytes();
    }

    pub fn read(stream: *binarystream.BinaryStream) !Address {
        const version = try stream.readUint8();
        if (version == 4) {
            var address_parts: [4]u8 = undefined;

            for (0..4) |i| {
                const byte = try stream.readUint8();
                address_parts[i] = ~byte & 0xff;
            }

            const address = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "{}.{}.{}.{}",
                .{ address_parts[0], address_parts[1], address_parts[2], address_parts[3] },
            );

            const port = try stream.readU16(.Big);
            return Address.init(address, port, version);
        }
        // TODO: Implement IPv6
        return AddressErrors.InvalidIPv4Address;
    }
};
