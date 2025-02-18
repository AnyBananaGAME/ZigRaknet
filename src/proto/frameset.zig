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

    pub fn serialize(self: *FrameSet) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        try stream.writeUint8(ID);
        try stream.writeU24(self.sequence, .Little);
        for (self.frames) |frame| {
            const frame_bytes = try frame.write();
            try stream.write(frame_bytes);
        }
        return try stream.getBytes();
    }

    pub fn deserialize(bytes: []const u8) !FrameSet {
        var stream = try BinaryStream.init(bytes, 0);
        _ = try stream.readUint8(); // ID
        const sequence = try stream.readU24(.Little);
        var frames: std.ArrayList(Frame) = std.ArrayList(Frame).init(std.heap.page_allocator);
        while (stream.offset < bytes.len) {
            const frame = try Frame.read(&stream);
            try frames.append(frame);
        }
        return FrameSet.init(sequence, frames.items);
    }
};
