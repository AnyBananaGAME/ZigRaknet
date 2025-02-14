const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const std = @import("std");

pub const ID: u8 = 0xc0;
pub const Ack = struct {
    sequences: []u32,
    allocator: std.mem.Allocator,

    pub fn init(sequences: []const u32) !Ack {
        const allocator = std.heap.page_allocator;
        const seq = try allocator.alloc(u32, sequences.len);
        @memcpy(seq, sequences);
        return Ack{
            .sequences = seq,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ack) void {
        self.allocator.free(self.sequences);
    }

    pub fn deserialize(data: []const u8) !Ack {
        const allocator = std.heap.page_allocator;
        var stream = try BinaryStream.init(data, 0);
        _ = try stream.readUint8();
        const count = try stream.readU16(.Big);

        var sequences = std.ArrayList(u32).init(allocator);
        defer sequences.deinit();

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const range = try stream.readBool();
            if (range) {
                const value = try stream.readU24(.Little);
                try sequences.append(value);
            } else {
                const start = try stream.readU24(.Little);
                const end = try stream.readU24(.Little);
                var j = start;
                while (j <= end) : (j += 1) {
                    try sequences.append(j);
                }
            }
        }

        return try Ack.init(sequences.items);
    }

    pub fn serialize(self: *Ack) ![]const u8 {
        var stream = try BinaryStream.init(null, 0);
        _ = try stream.writeUint8(ID);
        std.mem.sort(u32, self.sequences, {}, std.sort.asc(u32));

        var records: u16 = 0;
        var secondStream = try BinaryStream.init(null, 0);

        const count = self.sequences.len;
        if (count > 0) {
            var cursor: usize = 0;
            var start = self.sequences[0];
            var last = self.sequences[0];

            while (cursor < count - 1) {
                cursor += 1;
                const current = self.sequences[cursor];
                const diff = current - last;

                if (diff == 1) {
                    last = current;
                } else {
                    if (start == last) {
                        try secondStream.writeBool(true);
                        try secondStream.writeU24(start, .Little);
                    } else {
                        try secondStream.writeBool(false);
                        try secondStream.writeU24(start, .Little);
                        try secondStream.writeU24(last, .Little);
                    }
                    records += 1;
                    start = current;
                    last = current;
                }
            }

            if (start == last) {
                try secondStream.writeBool(true);
                try secondStream.writeU24(start, .Little);
            } else {
                try secondStream.writeBool(false);
                try secondStream.writeU24(start, .Little);
                try secondStream.writeU24(last, .Little);
            }
            records += 1;
        }

        try stream.writeU16(records, .Big);
        try stream.write(try secondStream.getBytes());
        return try stream.getBytes();
    }
};
