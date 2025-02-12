const BinaryStream = @import("../../binarystream/stream.zig").BinaryStream;
const Endianess = @import("../../binarystream/stream.zig").Endianess;
const std = @import("std");

pub const Reliability = enum(u3) { Unreliable, UnreliableSequenced, Reliable, ReliableOrdered, ReliableSequenced, UnreliableWithAckReceipt, ReliableWithAckReceipt, ReliableOrderedWithAckReceipt };
const Flags = enum(u8) { Split = 0x10, Valid = 0x80, Ack = 0x40, Nack = 0x20 };

pub const Frame = struct {
    reliable_frame_index: ?u32,
    sequence_frame_index: ?u32,
    ordered_frame_index: ?u32,

    order_channel: ?u8,
    reliability: Reliability,
    payload: []const u8,

    split_frame_index: ?u32,
    split_id: ?u16,
    split_size: ?u32,

    pub fn init(
        reliable_frame_index: ?u32,
        sequence_frame_index: ?u32,
        ordered_frame_index: ?u32,
        order_channel: ?u8,
        reliability: Reliability,
        payload: []const u8,
        split_frame_index: ?u32,
        split_id: ?u16,
        split_size: ?u32,
    ) Frame {
        return Frame{ .sequence_frame_index = sequence_frame_index, .ordered_frame_index = ordered_frame_index, .order_channel = order_channel, .reliability = reliability, .payload = payload, .split_frame_index = split_frame_index, .split_id = split_id, .split_size = split_size, .reliable_frame_index = reliable_frame_index };
    }

    pub fn isSplit(self: *const Frame) bool {
        return self.split_size != null and self.split_size.? > 0;
    }

    // pub fn read(stream: *binarystream.BinaryStream) !Frame {}

    pub fn write(self: *const Frame) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        const flags: u8 = (@as(u8, @intFromEnum(self.reliability)) << 5) |
            if (self.isSplit()) @intFromEnum(Flags.Split) else 0;
        try stream.writeUint8(flags);
        std.debug.print("Split: {any}\n", .{self.isSplit()});
        std.debug.print("flags: {any}\n", .{flags});
        std.debug.print("reliability: {any}\n", .{self.reliability});
        // Length is in bits, so multiply by 8
        const length_in_bits = @as(u16, @intCast(self.payload.len)) * 8;
        try stream.writeU16(length_in_bits, .Big);

        if (self.isReliable()) {
            try stream.writeU24(self.reliable_frame_index.?, .Little);
        }
        if (self.isSequenced()) {
            try stream.writeU24(self.sequence_frame_index.?, .Little);
        }
        if (self.isOrdered()) {
            try stream.writeU24(self.ordered_frame_index.?, .Little);
            try stream.writeUint8(self.order_channel.?);
        }
        if (self.isSplit()) {
            try stream.writeU32(self.split_size.?, .Big);
            try stream.writeU16(self.split_id.?, .Big);
            try stream.writeU32(self.split_frame_index.?, .Big);
        }
        try stream.write(self.payload);
        std.debug.print("Frame bytes: {any}\n", .{try stream.getBytes()});
        return try stream.getBytes();
    }

    pub fn isReliable(self: *const Frame) bool {
        if (self.reliability == Reliability.Reliable) return true;
        if (self.reliability == Reliability.ReliableOrdered) return true;
        if (self.reliability == Reliability.ReliableSequenced) return true;
        if (self.reliability == Reliability.ReliableWithAckReceipt) return true;
        if (self.reliability == Reliability.ReliableOrderedWithAckReceipt) return true;
        return false;
    }

    pub fn isSequenced(self: *const Frame) bool {
        if (self.reliability == Reliability.ReliableSequenced) return true;
        if (self.reliability == Reliability.UnreliableSequenced) return true;
        return false;
    }

    pub fn isOrdered(self: *const Frame) bool {
        if (self.reliability == Reliability.ReliableOrdered) return true;
        if (self.reliability == Reliability.ReliableOrderedWithAckReceipt) return true;
        return false;
    }

    pub fn isOrderExclusive(self: *const Frame) bool {
        if (self.reliability == Reliability.ReliableOrdered) return true;
        if (self.reliability == Reliability.ReliableOrderedWithAckReceipt) return true;
        return false;
    }

    pub fn getByteLength(self: *const Frame) usize {
        return 3 +
            self.payload.len +
            (if (self.isReliable()) @as(usize, 3) else 0) +
            (if (self.isSequenced()) @as(usize, 3) else 0) +
            (if (self.isOrdered()) @as(usize, 4) else 0) +
            (if (self.isSplit()) @as(usize, 10) else 0);
    }
};
