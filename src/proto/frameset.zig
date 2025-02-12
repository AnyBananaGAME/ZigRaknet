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
        try stream.writeU24(self.sequence, .Big);
        // Write each frame.
        for (self.frames) |frame| {
            const frame_bytes = try frame.write();
            try stream.write(frame_bytes);
        }
        std.debug.print("Frameset bytes: {any}\n", .{try stream.getBytes()});
        return try stream.getBytes();
    }
};
