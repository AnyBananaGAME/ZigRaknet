const Frame = @import("./types/frame.zig").Frame;
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const std = @import("std");

pub const ID: u8 = 0x80;
pub const FrameSet = struct {
    sequence: u32,
    frames: []const Frame,

    pub fn init(sequence: u32, frames: []const Frame) FrameSet {
        return FrameSet{ .sequence = sequence, .frames = frames };
    }

    pub fn writeToStream(self: *FrameSet, stream: *BinaryStream) !void {
        try stream.writeUint8(ID);
        try stream.writeU24(self.sequence, .Little);
        for (self.frames) |frame| {
            try frame.writeToStream(stream);
        }
    }

    pub fn serialize(self: *FrameSet) ![]const u8 {
        // Pre-calculate total size needed
        var total_size: usize = 4; // ID + sequence
        for (self.frames) |frame| {
            total_size += frame.getByteLength();
        }

        var stream = try BinaryStream.initCapacity(null, total_size);
        try self.writeToStream(&stream);
        return try stream.getBytes();
    }

    pub fn deserialize(bytes: []const u8) !FrameSet {
        var stream = try BinaryStream.init(bytes, 0);
        _ = try stream.readUint8(); // ID
        const sequence = try stream.readU24(.Little);

        // Pre-allocate frames with estimated capacity
        var frames = std.ArrayList(Frame).initCapacity(std.heap.page_allocator, @divFloor(bytes.len, 32) // Estimate average frame size as 32 bytes
        ) catch unreachable;

        while (stream.offset < bytes.len) {
            const frame = try Frame.read(&stream);
            try frames.append(frame);
        }
        return FrameSet.init(sequence, frames.items);
    }
};
