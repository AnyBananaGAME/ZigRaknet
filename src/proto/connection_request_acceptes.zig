const std = @import("std");
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const Address = @import("../proto/types/address.zig").Address;

pub const ID: u8 = 0x10;
pub const ConnectionRequestAccepted = struct {
    clientAddress: Address,
    clientId: u16,
    serverAddresses: [10]Address,
    clientSendTime: i64,
    serverSendTime: i64,

    pub fn deserialize(data: []const u8) !ConnectionRequestAccepted {
        var stream = try BinaryStream.init(data, 0);
        _ = try stream.readUint8(); // ID
        const clientAddress = try Address.read(&stream);
        const clientId = try stream.readU16(.Big);

        var serverAddresses: [10]Address = undefined;
        for (0..10) |i| {   
            serverAddresses[i] = try Address.read(&stream);
        }

        const clientSendTime = try stream.readI64(.Big);
        const serverSendTime = try stream.readI64(.Big);

        return ConnectionRequestAccepted{
            .clientAddress = clientAddress,
            .clientId = clientId,
            .serverAddresses = serverAddresses,
            .clientSendTime = clientSendTime,
            .serverSendTime = serverSendTime,
        };
    }
};
