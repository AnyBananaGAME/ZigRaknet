const std = @import("std");

pub const Endianess = enum {
    Little,
    Big,
};

pub const StreamErrors = error{ InvalidLength, OutOfBounds };

pub const BinaryStream = struct {
    offset: i16,
    binary: std.ArrayList(u8),

    pub fn init(binary: ?[]const u8, offset: ?i16) !BinaryStream {
        const allocator = std.heap.page_allocator;
        var list = std.ArrayList(u8).init(allocator);
        if (binary) |b| {
            try list.appendSlice(b);
        }
        return BinaryStream{
            .binary = list,
            .offset = offset orelse 0,
        };
    }

    pub fn new(allocator: std.mem.Allocator) BinaryStream {
        return BinaryStream{
            .binary = std.ArrayList(u8).init(allocator),
            .offset = 0,
        };
    }

    pub fn read(self: *BinaryStream, length: i16) ![]const u8 {
        if (length < 0) {
            return StreamErrors.InvalidLength;
        }
        if (self.offset + length > self.binary.items.len) {
            return StreamErrors.OutOfBounds;
        }
        const start = @as(usize, @intCast(self.offset));
        const end = @as(usize, @intCast(self.offset + length));
        self.offset += length;
        return self.binary.items[start..end];
    }

    pub fn write(self: *BinaryStream, data: []const u8) !void {
        try self.binary.appendSlice(data);
    }

    pub fn deinit(self: *BinaryStream) void {
        self.binary.deinit();
    }

    pub fn readUint8(self: *BinaryStream) !u8 {
        const bytes = try self.read(1);
        return bytes[0];
    }

    pub fn writeUint8(self: *BinaryStream, value: u8) !void {
        const data = &[_]u8{value};
        try self.write(data);
    }

    pub fn readBool(self: *BinaryStream) !bool {
        const bytes = try self.read(1);
        const boolean = bytes[0] != 0;
        return boolean;
    }

    pub fn writeBool(self: *BinaryStream, value: bool) !void {
        if (value) {
            try self.writeUint8(1);
        } else {
            try self.writeUint8(0);
        }
    }

    pub fn readI64(self: *BinaryStream, endianess: ?Endianess) !i64 {
        const bytes = try self.read(8);
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        return @as(i64, @bitCast(std.mem.readInt(u64, bytes[0..8], native_endian)));
    }

    pub fn writeI64(self: *BinaryStream, value: i64, endianess: ?Endianess) !void {
        var bytes: [8]u8 = undefined;
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        std.mem.writeInt(u64, &bytes, @as(u64, @bitCast(value)), native_endian);
        try self.write(bytes[0..8]);
    }

    pub fn readU16(self: *BinaryStream, endianess: ?Endianess) !u16 {
        const bytes = try self.read(2);
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        return std.mem.readInt(u16, bytes[0..2], native_endian);
    }

    pub fn writeU16(self: *BinaryStream, value: u16, endianess: ?Endianess) !void {
        var bytes: [2]u8 = undefined;
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        std.mem.writeInt(u16, &bytes, value, native_endian);
        try self.write(&bytes);
    }

    pub fn getBytes(self: *BinaryStream) ![]const u8 {
        return self.binary.items;
    }

    pub fn readU24(self: *BinaryStream, endianess: ?Endianess) !u32 {
        const bytes = try self.read(3);
        var temp: [4]u8 = undefined;
        const end = endianess orelse .Big;
        switch (end) {
            .Little => {
                temp[0] = bytes[0];
                temp[1] = bytes[1];
                temp[2] = bytes[2];
                temp[3] = 0;
            },
            .Big => {
                temp[0] = 0;
                temp[1] = bytes[0];
                temp[2] = bytes[1];
                temp[3] = bytes[2];
            },
        }
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        return std.mem.readInt(u32, &temp, native_endian);
    }

    pub fn writeU24(self: *BinaryStream, value: u32, endianess: ?Endianess) !void {
        var bytes: [4]u8 = undefined;
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        std.mem.writeInt(u32, &bytes, value, native_endian);
        switch (end) {
            .Big => try self.write(bytes[1..4]),
            .Little => try self.write(bytes[0..3]),
        }
    }

    pub fn readU32(self: *BinaryStream, endianess: ?Endianess) !u32 {
        const bytes = try self.read(4);
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        return std.mem.readInt(u32, bytes[0..4], native_endian);
    }

    pub fn writeU32(self: *BinaryStream, value: u32, endianess: ?Endianess) !void {
        var bytes: [4]u8 = undefined;
        const end = endianess orelse .Big;
        const native_endian = switch (end) {
            .Little => std.builtin.Endian.little,
            .Big => std.builtin.Endian.big,
        };
        std.mem.writeInt(u32, &bytes, value, native_endian);
        try self.write(&bytes);
    }

    pub fn readString16(self: *BinaryStream, endian: ?Endianess) ![]const u8 {
        const end = endian orelse .Big;
        const length = try self.readU16(end);
        const raw_data = try self.read(@as(i16, @intCast(length)));
        return raw_data;
    }

    pub fn writeString16(self: *BinaryStream, data: []const u8, endian: Endianess) !void {
        try self.writeU16(@as(u16, @intCast(data.len)), endian);
        try self.write(data);
    }

    pub fn reset(self: *BinaryStream) void {
        self.binary = std.ArrayList(u8).init(std.heap.page_allocator);
        self.offset = 0;
    }

    pub fn skip(self: *BinaryStream, length: i16) !void {
        self.offset += length;
    }
};
