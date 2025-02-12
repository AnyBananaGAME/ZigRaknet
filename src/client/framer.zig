const std = @import("std");
const Client = @import("client.zig").Client;
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const ConnectionRequest = @import("../proto/connection_request.zig").ConnectionRequest;
const Frame = @import("../proto/types/frame.zig").Frame;
const Reliability = @import("../proto/types/frame.zig").Reliability;
const FrameSet = @import("../proto/frameset.zig").FrameSet;

pub const Priority = enum(u8) { Medium, High };
pub const Framer = struct {
    client: *Client,
    outputOrderIndex: [32]u32,
    outputSequenceIndex: [32]u32,
    outputReliableIndex: u32 = 0,
    outputsplitIndex: u32 = 0,
    outputSequence: u32 = 0,
    outputFrames: std.ArrayList(Frame),
    allocator: std.mem.Allocator,

    pub fn init(client: *Client) !Framer {
        return Framer{
            .client = client,
            .outputOrderIndex = [_]u32{0} ** 32,
            .outputSequenceIndex = [_]u32{0} ** 32,
            .allocator = std.heap.page_allocator,
            .outputFrames = std.ArrayList(Frame).init(std.heap.page_allocator),
        };
    }

    pub fn handleMessage(self: *Framer, msg: []const u8) !void {
        _ = self; // autofix
        _ = msg; // autofix
    }

    pub fn deinit(self: *Framer) void {
        self.outputFrames.deinit();
    }

    pub fn sendConnection(self: *Framer) !void {
        const timestamp = std.time.timestamp();
        const connection_request = ConnectionRequest.init(self.client.guid, timestamp, false);
        const ser = try connection_request.serialize();
        var frame = frameIn(ser);
        try self.sendFrame(&frame);
    }

    pub fn frameIn(msg: []const u8) Frame {
        return Frame.init(null, null, null, 0, Reliability.ReliableOrdered, msg, null, null, null);
    }

    pub fn sendFrame(self: *Framer, frame: *Frame) !void {
        std.debug.print("Sending frame: {any}\n", .{frame});
        if (frame.isSequenced()) {
            frame.ordered_frame_index = self.outputOrderIndex[frame.order_channel.?];
            frame.sequence_frame_index = self.outputSequenceIndex[frame.order_channel.?];
            self.outputSequenceIndex[frame.order_channel.?] += 1;
        } else if (frame.isOrderExclusive()) {
            frame.ordered_frame_index = self.outputOrderIndex[frame.order_channel.?];
            self.outputOrderIndex[frame.order_channel.?] += 1;
            self.outputSequenceIndex[frame.order_channel.?] = 0;
        }

        const mtu = self.client.mtu_size - 36;
        const splitSize = @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(frame.payload.len)) / @as(f32, @floatFromInt(mtu)))));
        std.debug.print("Split size: {any}\n", .{splitSize});
        self.outputReliableIndex = self.outputReliableIndex + 1;
        frame.reliable_frame_index = self.outputReliableIndex;

        if (frame.payload.len > mtu) {
            std.debug.print("Splitting frame: {any}\n", .{frame});
            self.outputsplitIndex += 1;
            const splitId = @as(u16, @intCast(self.outputsplitIndex % 65536));
            var index: usize = 0;
            while (index < frame.payload.len) : (index += mtu) {
                const end = @min(index + mtu, frame.payload.len);
                var nFrame = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, frame.payload[index..end], @as(u32, @intCast(index / mtu)), splitId, splitSize);
                try self.queueFrame(&nFrame, .High);
            }
        } else {
            std.debug.print("Queueing frame: {any}\n", .{frame});
            try self.queueFrame(frame, .High);
        }
    }

    pub fn queueFrame(self: *Framer, frame: *Frame, priority: ?Priority) !void {
        const pr = priority orelse Priority.Medium;
        std.debug.print("Queueing frame: {any}\n", .{frame});
        var length: usize = 0;
        for (self.outputFrames.items) |f| {
            std.debug.print("Frame: {any}\n", .{f});
            length += f.getByteLength();
        }
        if (length + frame.getByteLength() > self.client.mtu_size - 36) {
            try self.sendQueue(@as(u32, @intCast(self.outputFrames.items.len)));
        }
        try self.outputFrames.append(frame.*);
        if (pr == Priority.High) {
            try self.sendQueue(1);
        }
    }

    pub fn sendQueue(self: *Framer, count: u32) !void {
        if (count <= 0) return;
        self.outputSequence += 1;
        const outputSeq = self.outputSequence;
        var frameset = FrameSet.init(outputSeq, self.outputFrames.items[0..@as(usize, count)]);
        const serialized = try frameset.serialize();
        std.debug.print("Sending frameset: {any}\n", .{serialized});
        try self.client.send(serialized);
        self.outputFrames.items = self.outputFrames.items[@as(usize, count)..];
    }
};
