const Address = @import("../proto/types/address.zig").Address;
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const std = @import("std");

pub const ID: u8 = 0x13;
pub const NewIncommingConnection = struct {
    server_address: Address,
    internal_addresses: [20]Address,
    incoming_timestamp: i64,
    server_timestamp: i64,

    pub fn init(server_address: Address, internal_addresses: [20]Address, incoming_timestamp: i64, server_timestamp: i64) NewIncommingConnection {
        return NewIncommingConnection{
            .server_address = server_address,
            .internal_addresses = internal_addresses,
            .incoming_timestamp = incoming_timestamp,
            .server_timestamp = server_timestamp,
        };
    }

    pub fn serialize(self: *NewIncommingConnection) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        try stream.writeUint8(ID);
        try stream.write(try self.server_address.write());
        std.debug.print("\n\nServer Address {any}\n", .{self.server_address});

        for (&self.internal_addresses) |addr| {
            const internal_addr = try addr.write();
            try stream.write(internal_addr);
        }
        try stream.writeI64(self.incoming_timestamp, .Big);
        try stream.writeI64(self.server_timestamp, .Big);
        return try stream.getBytes();
    }
};
