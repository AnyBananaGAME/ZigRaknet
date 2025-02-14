const std = @import("std");
const Client = @import("client.zig").Client;
const BinaryStream = @import("../binarystream/stream.zig").BinaryStream;
const Frame = @import("../proto/types/frame.zig").Frame;
const Address = @import("../proto/types/address.zig").Address;
const Reliability = @import("../proto/types/frame.zig").Reliability;
const FrameSet = @import("../proto/frameset.zig").FrameSet;
const StreamErrors = @import("../binarystream/stream.zig").StreamErrors;
const ConnectionRequest = @import("../proto/connection_request.zig").ConnectionRequest;
const ConnectionRequestAccepted = @import("../proto/connection_request_acceptes.zig").ConnectionRequestAccepted;
const NewIncommingConnection = @import("../proto/new-incomming-connection.zig").NewIncommingConnection;
const Ack = @import("../proto/ack.zig").Ack;
const ConnectedPing = @import("../proto/connected_ping.zig");

pub const Priority = enum(u8) { Medium, High };
const FragmentMap = std.AutoHashMap(u32, Frame);
const FrameOrderMap = std.AutoHashMap(u32, Frame);
const OrderingQueue = std.AutoHashMap(u32, FrameOrderMap);

pub const FramerError = error{
    MissingFragment,
    InvalidIPv4Address,
    AddressFamilyNotSupported,
    SystemResources,
    Unexpected,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    Overflow,
    InvalidEnd,
    InvalidCharacter,
    Incomplete,
    NonCanonical,
    AccessDenied,
    AddressNotAvailable,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    SocketNotReady,
    WouldBlock,
    FastOpenAlreadyInProgress,
    ConnectionResetByPeer,
    MessageTooBig,
    BrokenPipe,
    NetworkUnreachable,
    SocketNotConnected,
    UnreachableAddress,
    IncompleteWrite,
} || StreamErrors || std.mem.Allocator.Error;

pub const Framer = struct {
    client: *Client,
    outputOrderIndex: [32]u32,
    outputSequenceIndex: [32]u32,
    inputOrderIndex: std.ArrayList(u32),
    outputReliableIndex: u32 = 0,
    outputsplitIndex: u32 = 0,
    outputSequence: u32 = 0,
    outputFrames: std.ArrayList(Frame),
    output_backup: std.AutoHashMap(u32, []const Frame),
    currentQueueLength: usize = 0,
    receivedFrameSequences: std.AutoHashMap(u32, void),
    lostFrameSequences: std.AutoHashMap(u32, void),
    lastInputSequence: i32 = -1,
    fragmentsQueue: std.AutoHashMap(u16, FragmentMap),
    inputHighestSequenceIndex: [32]u32,
    inputOrderingQueue: OrderingQueue,
    allocator: std.mem.Allocator,
    split_buffer: BinaryStream,
    tickCount: u32 = 0,

    pub fn init(client: *Client) !Framer {
        const allocator = std.heap.page_allocator;
        const split_buffer = try BinaryStream.init(null, 0);

        return Framer{
            .client = client,
            .outputOrderIndex = [_]u32{0} ** 32,
            .outputSequenceIndex = [_]u32{0} ** 32,
            .inputHighestSequenceIndex = [_]u32{0} ** 32,
            .outputFrames = std.ArrayList(Frame).init(allocator),
            .receivedFrameSequences = std.AutoHashMap(u32, void).init(allocator),
            .lostFrameSequences = std.AutoHashMap(u32, void).init(allocator),
            .fragmentsQueue = std.AutoHashMap(u16, FragmentMap).init(allocator),
            .output_backup = std.AutoHashMap(u32, []const Frame).init(allocator),
            .outputReliableIndex = 0,
            .outputsplitIndex = 0,
            .outputSequence = 0,
            .inputOrderIndex = std.ArrayList(u32).init(allocator),
            .inputOrderingQueue = OrderingQueue.init(allocator),
            .lastInputSequence = -1,
            .allocator = allocator,
            .currentQueueLength = 0,
            .split_buffer = split_buffer,
            .tickCount = 0,
        };
    }

    pub fn incomingBatch(self: *Framer, msg: []const u8) !void {
        if (self.client.debug) std.debug.print("\n\nIncoming batch: {any}\n\n", .{msg});
        switch (msg[0]) {
            0 => {},
            16 => {
                const data = try ConnectionRequestAccepted.deserialize(msg);
                if (self.client.debug) std.debug.print("\n\nIncoming ConnectionRequestAccepted: {any}\n\n", .{data});
                const server_address = Address.init(self.client.host, self.client.port, 4);
                const client_address = Address.init("127.0.0.1", self.client.socket.port, 4);
                const timestamp = @as(i64, std.time.milliTimestamp());
                var addresses: [20]Address = undefined;
                for (&addresses) |*addr| {
                    addr.* = client_address;
                }
                var packet = NewIncommingConnection.init(server_address, addresses, timestamp, data.serverSendTime);
                const serialized = try packet.serialize();
                var frame = frameIn(serialized);
                try self.sendFrame(&frame);
                const end = std.time.milliTimestamp() - self.client.conTime;
                std.debug.print("\n\nConnection time: {d}ms\n", .{end});
                std.debug.print("Client Con Time {d}\n", .{self.client.conTime});
                std.debug.print("Current Time {d}\n", .{std.time.milliTimestamp()});
            },
            0x15 => {
                std.debug.print("\nReceived Disconnect {any}\n", .{msg});
            },
            else => {
                if (self.client.debug) std.debug.print("\n\nIncoming batch Unknown packet: {any}\n\n", .{msg[0]});
            },
        }
    }

    pub fn tick(self: *Framer) !void {
        self.tickCount += 1;
        const size = self.receivedFrameSequences.count();
        var sequences = try std.ArrayList(u32).initCapacity(self.allocator, size);
        defer sequences.deinit();

        if (self.tickCount % 50 == 0) {
            var ping = ConnectedPing.ConnectedPing.init();
            const serialized = try ping.serialize();
            var frame = frameIn(serialized);
            try self.sendFrame(&frame);
        }

        if (size > 0) {
            var sequences2 = try std.ArrayList(u32).initCapacity(self.allocator, size);
            defer sequences2.deinit();

            var it = self.receivedFrameSequences.keyIterator();
            while (it.next()) |key| {
                try sequences2.append(key.*);
                try sequences.append(key.*);
            }

            var ack = try Ack.init(sequences2.items);
            self.receivedFrameSequences.clearAndFree();
            const serialized = try ack.serialize();
            std.debug.print("Sending Ack {any}\n", .{1});
            try self.client.send(serialized);
        }
    }

    pub fn onAck(self: *Framer, ack: Ack) !void {
        std.debug.print("Received Ack {any}\n", .{1});
        const sequences = ack.sequences;
        for (sequences) |seq| {
            if (self.output_backup.get(seq)) |frames| {
                self.allocator.free(frames);
            }
            _ = self.output_backup.remove(seq);
        }
    }

    pub fn getInputIndex(self: *Framer, channel: u32) !u32 {
        while (self.inputOrderIndex.items.len <= channel) {
            try self.inputOrderIndex.append(0);
        }
        return self.inputOrderIndex.items[channel];
    }

    pub fn setInputIndex(self: *Framer, channel: u32, value: u32) !void {
        while (self.inputOrderIndex.items.len <= channel) {
            try self.inputOrderIndex.append(0);
        }
        self.inputOrderIndex.items[channel] = value;
    }

    pub fn handleMessage(self: *Framer, msg: []const u8) !void {
        const frameSet = try FrameSet.deserialize(msg);
        if (self.receivedFrameSequences.contains(frameSet.sequence)) {
            std.debug.print("Received duplicate frameset with sequence {any}\n", .{frameSet.sequence});
            return;
        }
        if (self.lostFrameSequences.contains(frameSet.sequence)) {
            _ = self.lostFrameSequences.remove(frameSet.sequence);
        }

        if (frameSet.sequence < self.lastInputSequence or frameSet.sequence == self.lastInputSequence) {
            std.debug.print("Dropping out of order frameset with sequence {any}\n", .{frameSet.sequence});
            return;
        }

        self.receivedFrameSequences.put(frameSet.sequence, {}) catch {};
        if (frameSet.sequence - @as(u32, @intCast(self.lastInputSequence + 1)) > 1) {
            var index: u32 = @intCast(self.lastInputSequence + 1);
            while (index < frameSet.sequence) : (index += 1) {
                self.lostFrameSequences.put(index, {}) catch {};
            }
        }

        self.lastInputSequence = @as(i32, @intCast(frameSet.sequence));

        for (frameSet.frames) |frame| {
            try self.handleFrame(frame);
        }

        // std.debug.print("Frameset {any}", .{frameSet});
    }

    pub fn handleFrame(self: *Framer, frame: Frame) FramerError!void {
        if (frame.isSplit()) {
            try self.handleSplit(frame);
        } else if (frame.isSequenced()) {
            if (frame.sequence_frame_index.? < self.inputHighestSequenceIndex[frame.order_channel.?] or frame.ordered_frame_index.? < try self.getInputIndex(frame.order_channel.?)) {
                std.debug.print("Dropping out of order sequenced frame with sequence {any} and channel {any}\n", .{ frame.sequence_frame_index, frame.order_channel });
                return;
            }
            self.inputHighestSequenceIndex[frame.order_channel.?] = frame.sequence_frame_index.? + 1;
            try self.incomingBatch(frame.payload);
        } else if (frame.isOrdered()) {
            const channel = frame.order_channel.?;
            const currentIndex = try self.getInputIndex(channel);

            if (frame.ordered_frame_index.? == currentIndex) {
                self.inputHighestSequenceIndex[channel] = frame.ordered_frame_index.? + 1;
                try self.setInputIndex(channel, currentIndex + 1);
                try self.incomingBatch(frame.payload);

                var index: u32 = currentIndex + 1;
                if (self.inputOrderingQueue.getPtr(channel)) |outOfOrderQueue| {
                    while (true) {
                        const maybeFrame = outOfOrderQueue.get(index);
                        if (maybeFrame) |framePtr| {
                            try self.incomingBatch(framePtr.payload);
                            _ = outOfOrderQueue.remove(index);
                            index += 1;
                        } else break;
                    }
                    try self.setInputIndex(channel, index);
                }
            } else if (frame.ordered_frame_index.? > currentIndex) {
                if (self.inputOrderingQueue.getPtr(channel)) |unordered| {
                    try unordered.put(frame.ordered_frame_index.?, frame);
                } else {
                    var newMap = FrameOrderMap.init(self.allocator);
                    try newMap.put(frame.ordered_frame_index.?, frame);
                    try self.inputOrderingQueue.put(channel, newMap);
                }
            }
        } else {
            try self.incomingBatch(frame.payload);
        }
    }

    pub fn handleSplit(self: *Framer, frame: Frame) FramerError!void {
        if (self.fragmentsQueue.getPtr(frame.split_id.?)) |fragment_map| {
            try fragment_map.put(frame.split_frame_index.?, frame);

            if (fragment_map.count() == frame.split_size.?) {
                if (self.client.debug) std.debug.print("Complete split frame received\n", .{});
                self.split_buffer.reset();
                var i: u32 = 0;
                while (i < frame.split_size.?) : (i += 1) {
                    if (fragment_map.get(i)) |sframe| {
                        try self.split_buffer.write(sframe.payload);
                    } else {
                        if (self.client.debug) std.debug.print("Missing fragment at index {d}\n", .{i});
                        return FramerError.MissingFragment;
                    }
                }
                const nFrame = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, try self.split_buffer.getBytes(), null, null, null);
                _ = self.fragmentsQueue.remove(frame.split_id.?);
                try self.handleFrame(nFrame);
            }
        } else {
            var new_map = FragmentMap.init(self.allocator);
            errdefer new_map.deinit();
            try new_map.put(frame.split_frame_index.?, frame);
            try self.fragmentsQueue.put(frame.split_id.?, new_map);
        }
        if (self.client.debug) std.debug.print("Split frame {any}", .{frame});
    }

    pub fn deinit(self: *Framer) void {
        self.outputFrames.deinit();
        self.receivedFrameSequences.deinit();
        self.lostFrameSequences.deinit();
        self.inputOrderIndex.deinit();

        var it = self.fragmentsQueue.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.fragmentsQueue.deinit();
        var it2 = self.inputOrderingQueue.iterator();
        while (it2.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.inputOrderingQueue.deinit();
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
        if (self.client.debug) std.debug.print("Sending frame: {any}\n", .{frame});
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
        if (self.client.debug) std.debug.print("Split size: {any}\n", .{splitSize});
        self.outputReliableIndex = self.outputReliableIndex + 1;
        frame.reliable_frame_index = self.outputReliableIndex;

        if (frame.payload.len > mtu) {
            self.outputsplitIndex += 1;
            const splitId = @as(u16, @intCast(self.outputsplitIndex % 65536));
            var index: usize = 0;
            while (index < frame.payload.len) : (index += mtu) {
                const end = @min(index + mtu, frame.payload.len);
                var nFrame = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, frame.payload[index..end], @as(u32, @intCast(index / mtu)), splitId, splitSize);
                try self.queueFrame(&nFrame, .High);
            }
        } else {
            try self.queueFrame(frame, .High);
        }
    }

    pub fn queueFrame(self: *Framer, frame: *Frame, priority: ?Priority) !void {
        const pr = priority orelse Priority.Medium;
        const frame_length = frame.getByteLength();

        if (self.currentQueueLength + frame_length > self.client.mtu_size - 36) {
            try self.sendQueue(@as(u32, @intCast(self.outputFrames.items.len)));
        }

        try self.outputFrames.append(frame.*);
        self.currentQueueLength += frame_length;

        if (pr == Priority.High) {
            try self.sendQueue(1);
        }
    }

    pub fn sendQueue(self: *Framer, count: u32) !void {
        if (count <= 0) return;
        const outputSeq = self.outputSequence;
        var frameset = FrameSet.init(outputSeq, self.outputFrames.items[0..@as(usize, count)]);
        const frames_copy = try self.allocator.dupe(Frame, frameset.frames);
        try self.output_backup.put(self.outputSequence, frames_copy);
        const serialized = try frameset.serialize();
        try self.client.send(serialized);
        self.outputSequence += 1;

        var removed_length: usize = 0;
        for (self.outputFrames.items[0..@as(usize, count)]) |f| {
            removed_length += f.getByteLength();
        }
        self.currentQueueLength -= removed_length;

        var remaining = try std.ArrayList(Frame).initCapacity(self.allocator, self.outputFrames.items.len - count);
        try remaining.appendSlice(self.outputFrames.items[@as(usize, count)..]);
        self.outputFrames.deinit();
        self.outputFrames = remaining;
    }
};
