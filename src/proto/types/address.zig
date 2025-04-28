const binarystream = @import("../../binarystream/stream.zig");
const std = @import("std");

pub const AddressError = error{
    InvalidIPv4Address,
    InvalidIPv6Address,
    InvalidAddressVersion,
};

pub const Address = struct {
    address: []const u8,
    port: u16,
    version: u8,

    pub fn init(address: []const u8, port: u16, version: u8) Address {
        const addr_copy = std.heap.page_allocator.alloc(u8, address.len) catch |err| {
            std.debug.print("Failed to allocate memory for address: {any}\n", .{err});
            return Address{
                .address = address,
                .port = port,
                .version = version,
            };
        };
        @memcpy(addr_copy, address);
        return Address{
            .address = addr_copy,
            .port = port,
            .version = version,
        };
    }

    pub fn write(self: Address) ![]const u8 {
        var stream = try binarystream.BinaryStream.init(null, 0);
        try stream.writeUint8(self.version);
        if (self.version == 4) {
            var parts = std.mem.tokenizeScalar(u8, self.address, '.');
            var part_count: usize = 0;
            while (parts.next()) |part| {
                part_count += 1;
                const b = std.fmt.parseInt(u8, part, 10) catch |err| {
                    std.debug.print("Invalid IPv4 address part '{s}': {any}\n", .{ part, err });
                    return AddressError.InvalidIPv4Address;
                };
                try stream.writeUint8((~b) & 0xff);
            }
            if (part_count != 4) {
                std.debug.print("Invalid IPv4 address '{s}': expected 4 parts, got {d}\n", .{ self.address, part_count });
                return AddressError.InvalidIPv4Address;
            }
            try stream.writeU16(self.port, .Big);
        } else if (self.version == 6) {
            try stream.writeU16(23, .Big); // IPv6 header
            try stream.writeU16(self.port, .Big);
            try stream.writeU32(0, .Big); // Padding

            var parts = std.mem.tokenizeScalar(u8, self.address, ':');
            var part_count: usize = 0;
            while (parts.next()) |part| {
                part_count += 1;
                if (part_count > 8) {
                    std.debug.print("Invalid IPv6 address '{s}': too many parts\n", .{self.address});
                    return AddressError.InvalidIPv6Address;
                }
                const num = try std.fmt.parseInt(u16, part, 16);
                try stream.writeU16(num ^ 0xffff, .Big);
            }
            if (part_count != 8) {
                std.debug.print("Invalid IPv6 address '{s}': expected 8 parts, got {d}\n", .{ self.address, part_count });
                return AddressError.InvalidIPv6Address;
            }
            try stream.writeU32(0, .Big); // Padding
        } else {
            std.debug.print("Invalid IP version: {d}\n", .{self.version});
            return AddressError.InvalidAddressVersion;
        }
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
        } else if (version == 6) {
            _ = try stream.readU16(.Big); // Skip IPv6 header (23)
            const port = try stream.readU16(.Big);
            _ = try stream.readU32(.Big); // Skip padding

            var address_parts: [8]u16 = undefined;
            for (0..8) |i| {
                const part = try stream.readU16(.Big);
                address_parts[i] = part ^ 0xffff;
            }

            const address = try std.fmt.allocPrint(
                std.heap.page_allocator,
                "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}",
                .{
                    address_parts[0], address_parts[1], address_parts[2], address_parts[3],
                    address_parts[4], address_parts[5], address_parts[6], address_parts[7],
                },
            );

            _ = try stream.readU32(.Big); // Skip padding
            return Address.init(address, port, version);
        } else {
            std.debug.print("Invalid IP version: {d}\n", .{version});
            return AddressError.InvalidAddressVersion;
        }
    }

    pub fn deinit(self: *const Address) void {
        std.heap.page_allocator.free(self.address);
    }
};
