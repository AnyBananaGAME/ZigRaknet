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
const ConnectedPong = @import("../proto/connected_pong.zig");
const timing = @import("../debug/timing.zig");

pub const Priority = enum(u8) { Medium, High };
const FragmentMap = std.AutoHashMap(u32, Frame);
const FrameOrderMap = std.AutoHashMap(u32, Frame);
const OrderingQueue = std.AutoHashMap(u32, FrameOrderMap);

pub const FramerError = error{
    InvalidFrame,
    MissingFragment,
    IncompleteWrite,
    OutOfMemory,
    InvalidLength,
    OutOfBounds,
    VarIntTooBig,
    InvalidIPv4Address,
    InvalidIPv6Address,
    InvalidAddressVersion,
    Incomplete,
    ConnectionRefused,
    Overflow,
    FileNotFound,
    NameTooLong,
    SymLinkLoop,
    NotDir,
    SocketNotConnected,
    InvalidCharacter,
    AddressFamilyNotSupported,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
    InvalidEnd,
    NonCanonical,
    FastOpenAlreadyInProgress,
    MessageTooBig,
    NetworkUnreachable,
    UnreachableAddress,
    AddressNotAvailable,
    SocketNotReady,
} || std.fs.File.WriteError || std.mem.Allocator.Error;

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
    mutex: std.Thread.Mutex,
    frame_arena: std.heap.ArenaAllocator,
    chunk_buffer: []u8,
    debug: bool = false,
    serialize_buffer: std.ArrayList(u8),
    frame_buffer: [1500]u8 = undefined,
    frame_buffer_len: usize = 0,
    output_buffer: [1500 * 32]u8 = undefined,
    output_buffer_len: usize = 0,
    frame_queue: [256]Frame = undefined,
    frame_queue_len: usize = 0,
    timings: timing.TimingMap,

    pub fn init(client: *Client) !Framer {
        const allocator = std.heap.page_allocator;
        const split_buffer = try BinaryStream.init(null, 0);
        const chunk_buffer = try allocator.alloc(u8, 1500 * 32);

        return Framer{
            .client = client,
            .outputOrderIndex = [_]u32{0} ** 32,
            .outputSequenceIndex = [_]u32{0} ** 32,
            .inputHighestSequenceIndex = [_]u32{0} ** 32,
            .outputFrames = std.ArrayList(Frame).initCapacity(allocator, 256) catch unreachable,
            .receivedFrameSequences = std.AutoHashMap(u32, void).init(allocator),
            .lostFrameSequences = std.AutoHashMap(u32, void).init(allocator),
            .fragmentsQueue = std.AutoHashMap(u16, FragmentMap).init(allocator),
            .output_backup = std.AutoHashMap(u32, []const Frame).init(allocator),
            .outputReliableIndex = 0,
            .outputsplitIndex = 0,
            .outputSequence = 0,
            .inputOrderIndex = std.ArrayList(u32).initCapacity(allocator, 32) catch unreachable,
            .inputOrderingQueue = OrderingQueue.init(allocator),
            .lastInputSequence = -1,
            .allocator = allocator,
            .currentQueueLength = 0,
            .split_buffer = split_buffer,
            .tickCount = 0,
            .mutex = std.Thread.Mutex{},
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .chunk_buffer = chunk_buffer,
            .debug = client.debug,
            .serialize_buffer = std.ArrayList(u8).initCapacity(allocator, 1500) catch unreachable,
            .frame_buffer_len = 0,
            .output_buffer_len = 0,
            .frame_queue_len = 0,
            .timings = timing.TimingMap.init(allocator),
        };
    }

    pub fn incomingBatch(self: *Framer, msg: []const u8) !void {
        if (self.client.debug) std.debug.print("Incoming batch with type: {d}, length: {d}\n", .{ msg[0], msg.len });
        try self.timings.start("framer_incoming_batch");
        defer self.timings.end("framer_incoming_batch");

        switch (msg[0]) {
            ConnectedPing.ID => {
                const data = try ConnectedPing.ConnectedPing.deserialize(msg);
                if (self.client.debug) std.debug.print("Incoming ConnectedPing: {any}\n", .{data});
                var pong = ConnectedPong.ConnectedPong.init(data.timestamp);
                const serialized = try pong.serialize();
                var frame = frameIn(serialized);
                try self.sendFrame(&frame);
            },
            16 => {
                if (self.client.debug) std.debug.print("Processing ConnectionRequestAccepted\n", .{});
                const data = try ConnectionRequestAccepted.deserialize(msg);
                if (self.client.debug) std.debug.print("ConnectionRequestAccepted data: {any}\n", .{data});

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

                if (self.client.debug) std.debug.print("Sent NewIncommingConnection response\n", .{});
                self.client.connected = true;
                const connect_msg = try std.fmt.allocPrint(self.allocator, "Connected to {s}:{d}", .{ self.client.host, self.client.port });
                self.client.emitter.emit("connect", connect_msg);
                self.allocator.free(connect_msg);
            },
            0x15 => {
                if (self.client.debug) std.debug.print("Received disconnect packet\n", .{});
                const disconnect_msg = try std.fmt.allocPrint(self.allocator, "Disconnected from {s}:{d}", .{ self.client.host, self.client.port });
                self.client.emitter.emit("disconnect", disconnect_msg);
                self.allocator.free(disconnect_msg);
                self.client.socket.deinit();
            },
            254 => {
                if (self.client.debug) std.debug.print("Received encapsulated message: {any}\n", .{msg});
                self.client.emitter.emit("encapsulated", msg);
            },
            else => {
                if (self.client.debug) std.debug.print("Unknown packet type: {d}, data: {any}\n", .{ msg[0], msg });
            },
        }
    }

    pub fn tick(self: *Framer) !void {
        try self.timings.start("framer_tick");
        defer self.timings.end("framer_tick");

        self.tickCount += 1;

        self.mutex.lock();
        defer self.mutex.unlock();

        const lost_size = self.lostFrameSequences.count();
        if (lost_size > 0) {
            var sequences = try std.ArrayList(u32).initCapacity(self.allocator, lost_size);
            defer sequences.deinit();

            var it = self.lostFrameSequences.keyIterator();
            while (it.next()) |key| {
                try sequences.append(key.*);
            }

            var nack = try Ack.init(sequences.items);
            const serialized = try nack.serialize();
            var nack_packet = try self.allocator.alloc(u8, serialized.len);
            defer self.allocator.free(nack_packet);
            @memcpy(nack_packet, serialized);
            nack_packet[0] = 0xA0;
            try self.client.send(nack_packet);

            self.lostFrameSequences.clearAndFree();
        }

        const size = self.receivedFrameSequences.count();
        if (size > 0) {
            var sequences = try std.ArrayList(u32).initCapacity(self.allocator, size);
            defer sequences.deinit();

            var it = self.receivedFrameSequences.keyIterator();
            while (it.next()) |key| {
                try sequences.append(key.*);
            }

            var ack = try Ack.init(sequences.items);
            self.receivedFrameSequences.clearAndFree();
            const serialized = try ack.serialize();
            try self.client.send(serialized);
        }

        if (self.tickCount % 50 == 0) {
            var ping = ConnectedPing.ConnectedPing.init();
            const serialized = try ping.serialize();
            var frame = frameIn(serialized);
            try self.sendFrame(&frame);
        }
    }

    pub fn onAck(self: *Framer, ack: Ack) !void {
        if (self.client.debug) std.debug.print("Received Ack {any}\n", .{ack.sequences});
        const sequences = ack.sequences;
        for (sequences) |seq| {
            if (self.output_backup.get(seq)) |frames| {
                self.allocator.free(frames);
            }
            _ = self.output_backup.remove(seq);
        }
    }

    pub fn onNack(self: *Framer, nack: Ack) !void {
        if (self.client.debug) std.debug.print("Received Nack {any}\n", .{nack.sequences});

        for (nack.sequences) |seq| {
            if (self.output_backup.get(seq)) |frames| {
                for (frames) |backup_frame| {
                    var frame = backup_frame;
                    try self.sendFrame(&frame);
                }
            } else if (self.client.debug) {
                std.debug.print("Received NACK for unknown sequence {d}\n", .{seq});
            }
        }
    }

    pub fn getInputIndex(self: *Framer, channel: u32) !u32 {
        if (channel >= self.inputOrderIndex.items.len) {
            try self.inputOrderIndex.appendNTimes(0, channel - self.inputOrderIndex.items.len + 1);
        }
        return self.inputOrderIndex.items[channel];
    }

    pub fn setInputIndex(self: *Framer, channel: u32, value: u32) !void {
        if (channel >= self.inputOrderIndex.items.len) {
            try self.inputOrderIndex.appendNTimes(0, channel - self.inputOrderIndex.items.len + 1);
        }
        self.inputOrderIndex.items[channel] = value;
    }

    pub fn handleMessage(self: *Framer, msg: []const u8) !void {
        try self.timings.start("framer_handle_message");
        defer self.timings.end("framer_handle_message");

        if (msg[0] == 0xC0) {
            const ack = try Ack.deserialize(msg);
            try self.onAck(ack);
            return;
        } else if (msg[0] == 0xA0) {
            const nack = try Ack.deserialize(msg);
            try self.onNack(nack);
            return;
        }

        const frameSet = try FrameSet.deserialize(msg);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.client.debug) std.debug.print("Handling FrameSet with sequence {d}, frames: {d}\n", .{ frameSet.sequence, frameSet.frames.len });

        try self.receivedFrameSequences.put(frameSet.sequence, {});

        if (frameSet.sequence <= self.lastInputSequence) {
            if (self.client.debug) std.debug.print("Dropping duplicate frameset with sequence {d}\n", .{frameSet.sequence});
            return;
        }

        const lastInputSeqUnsigned = if (self.lastInputSequence < 0)
            0
        else
            @as(u32, @intCast(self.lastInputSequence));

        if (frameSet.sequence > lastInputSeqUnsigned + 1) {
            if (self.client.debug) std.debug.print("Out-of-order frameset {d}, marking lost frames\n", .{frameSet.sequence});
            var index = lastInputSeqUnsigned +% 1;
            while (index < frameSet.sequence) : (index +%= 1) {
                try self.lostFrameSequences.put(index, {});
            }
        }

        for (frameSet.frames) |frame| {
            try self.handleFrameInternal(frame);
        }

        self.lastInputSequence = @intCast(frameSet.sequence);

        var sequences = try std.ArrayList(u32).initCapacity(self.allocator, 1);
        defer sequences.deinit();
        try sequences.append(frameSet.sequence);
        var ack = try Ack.init(sequences.items);
        const serialized = try ack.serialize();
        try self.client.send(serialized);
    }

    pub fn handleFrameInternal(self: *Framer, frame: Frame) FramerError!void {
        try self.timings.start("frame_processing");
        defer self.timings.end("frame_processing");

        if (!frame.isSplit() and !frame.isSequenced() and !frame.isOrdered()) {
            try self.incomingBatch(frame.payload);
            return;
        }

        if (frame.isSplit()) {
            try self.handleSplitInternal(frame);
            return;
        }

        const channel = frame.order_channel orelse return self.incomingBatch(frame.payload);

        if (frame.isSequenced()) {
            const currentSeqIndex = self.inputHighestSequenceIndex[channel];
            const currentOrderIndex = try self.getInputIndex(channel);

            if (frame.sequence_frame_index.? < currentSeqIndex or
                frame.ordered_frame_index.? < currentOrderIndex)
            {
                if (self.client.debug) std.debug.print("Dropping out-of-order frame\n", .{});
                return;
            }

            self.inputHighestSequenceIndex[channel] = frame.sequence_frame_index.? + 1;
            try self.incomingBatch(frame.payload);
            return;
        }

        if (frame.isOrdered()) {
            const currentIndex = try self.getInputIndex(channel);
            if (frame.ordered_frame_index.? == currentIndex) {
                self.inputHighestSequenceIndex[channel] = 0;
                try self.setInputIndex(channel, currentIndex + 1);
                try self.incomingBatch(frame.payload);

                if (self.inputOrderingQueue.getPtr(channel)) |outOfOrderQueue| {
                    var index = currentIndex + 1;
                    while (outOfOrderQueue.get(index)) |queuedFrame| {
                        try self.incomingBatch(queuedFrame.payload);
                        _ = outOfOrderQueue.remove(index);
                        index += 1;
                    }
                    try self.setInputIndex(channel, index);

                    if (outOfOrderQueue.count() == 0) {
                        outOfOrderQueue.deinit();
                        _ = self.inputOrderingQueue.remove(channel);
                    }
                }
            } else if (frame.ordered_frame_index.? > currentIndex) {
                try self.queueOrderedFrame(frame, channel);
            }
        }
    }

    pub fn handleFrame(self: *Framer, frame: Frame) FramerError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handleFrameInternal(frame);
    }

    fn processOrderedFrame(self: *Framer, frame: Frame, channel: u32, currentIndex: u32) !void {
        self.inputHighestSequenceIndex[channel] = frame.ordered_frame_index.? + 1;
        try self.setInputIndex(channel, currentIndex + 1);
        try self.incomingBatch(frame.payload);

        if (self.inputOrderingQueue.getPtr(channel)) |outOfOrderQueue| {
            var index = currentIndex + 1;
            var processed: u32 = 0;
            const max_process = 32;

            var to_process: [32]Frame = undefined;
            var to_process_len: usize = 0;

            while (processed < max_process) : (processed += 1) {
                if (outOfOrderQueue.get(index)) |framePtr| {
                    to_process[to_process_len] = framePtr;
                    to_process_len += 1;
                    _ = outOfOrderQueue.remove(index);
                    index += 1;
                } else break;
            }

            for (to_process[0..to_process_len]) |framePtr| {
                try self.incomingBatch(framePtr.payload);
            }

            try self.setInputIndex(channel, index);

            if (outOfOrderQueue.count() == 0) {
                outOfOrderQueue.deinit();
                _ = self.inputOrderingQueue.remove(channel);
            }
        }
    }

    fn queueOrderedFrame(self: *Framer, frame: Frame, channel: u32) !void {
        if (self.inputOrderingQueue.getPtr(channel)) |unordered| {
            try unordered.put(frame.ordered_frame_index.?, frame);
        } else {
            var newMap = FrameOrderMap.init(self.allocator);
            try newMap.put(frame.ordered_frame_index.?, frame);
            try self.inputOrderingQueue.put(channel, newMap);
        }
    }

    pub fn handleSplitInternal(self: *Framer, frame: Frame) FramerError!void {
        try self.timings.start("split_processing");
        defer self.timings.end("split_processing");

        if (frame.split_id == null or frame.split_size == null or frame.split_frame_index == null) {
            return error.InvalidFrame;
        }

        const splitId = frame.split_id.?;
        const splitSize = frame.split_size.?;
        const splitIndex = frame.split_frame_index.?;

        var fragment_map = if (self.fragmentsQueue.getPtr(splitId)) |map|
            map
        else blk: {
            const new_map = FragmentMap.init(self.allocator);
            try self.fragmentsQueue.put(splitId, new_map);
            break :blk self.fragmentsQueue.getPtr(splitId).?;
        };

        try fragment_map.put(splitIndex, frame);

        if (fragment_map.count() == splitSize) {
            var total_size: usize = 0;
            var i: u32 = 0;
            while (i < splitSize) : (i += 1) {
                if (fragment_map.get(i)) |sframe| {
                    total_size += sframe.payload.len;
                }
            }

            try self.serialize_buffer.ensureTotalCapacity(total_size);
            self.serialize_buffer.clearRetainingCapacity();

            i = 0;
            while (i < splitSize) : (i += 1) {
                const sframe = fragment_map.get(i) orelse return error.MissingFragment;
                try self.serialize_buffer.appendSlice(sframe.payload);
            }

            const payload = try self.frame_arena.allocator().dupe(u8, self.serialize_buffer.items);
            const nFrame = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, payload, null, null, null);

            fragment_map.deinit();
            _ = self.fragmentsQueue.remove(splitId);

            try self.handleFrameInternal(nFrame);
        }
    }

    pub fn handleSplit(self: *Framer, frame: Frame) FramerError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handleSplitInternal(frame);
    }

    pub fn deinit(self: *Framer) void {
        self.outputFrames.deinit();
        self.receivedFrameSequences.deinit();
        self.lostFrameSequences.deinit();
        self.inputOrderIndex.deinit();
        self.frame_arena.deinit();
        self.allocator.free(self.chunk_buffer);
        self.split_buffer.deinit();

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

        var it3 = self.output_backup.iterator();
        while (it3.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.output_backup.deinit();

        self.serialize_buffer.deinit();
        self.timings.deinit();
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
        try self.timings.start("frame_send");
        defer self.timings.end("frame_send");

        if (self.client.debug) std.debug.print("Sending frame: {any}\n", .{frame});

        if (frame.order_channel) |channel| {
            if (frame.isSequenced()) {
                frame.ordered_frame_index = self.outputOrderIndex[channel];
                frame.sequence_frame_index = self.outputSequenceIndex[channel];
                self.outputSequenceIndex[channel] += 1;
            } else if (frame.isOrderExclusive()) {
                frame.ordered_frame_index = self.outputOrderIndex[channel];
                self.outputOrderIndex[channel] += 1;
                self.outputSequenceIndex[channel] = 0;
            }
        }

        self.outputReliableIndex += 1;
        frame.reliable_frame_index = self.outputReliableIndex;

        const mtu = self.client.mtu_size - 36;
        if (frame.payload.len <= mtu) {
            return self.queueFrame(frame, .High);
        }

        const splitSize = (frame.payload.len + mtu - 1) / mtu;
        self.outputsplitIndex += 1;
        const splitId = @as(u16, @intCast(self.outputsplitIndex % 65536));

        var offset: usize = 0;
        var chunk_index: usize = 0;
        while (offset < frame.payload.len) : ({
            offset += mtu;
            chunk_index += 1;
        }) {
            const end = @min(offset + mtu, frame.payload.len);
            const chunk_len = end - offset;

            @memcpy(self.chunk_buffer[offset..][0..chunk_len], frame.payload[offset..end]);

            var nFrame = Frame.init(frame.reliable_frame_index, frame.sequence_frame_index, frame.ordered_frame_index, frame.order_channel, frame.reliability, self.chunk_buffer[offset..][0..chunk_len], @intCast(chunk_index), splitId, @intCast(splitSize));

            try self.queueFrame(&nFrame, .High);
        }

        _ = self.frame_arena.reset(.retain_capacity);
    }

    pub fn queueFrame(self: *Framer, frame: *const Frame, priority: Priority) !void {
        try self.timings.start("frame_queue");
        defer self.timings.end("frame_queue");

        const frame_length = frame.getByteLength();

        if (self.frame_queue_len >= self.frame_queue.len or
            self.currentQueueLength + frame_length > self.client.mtu_size - 36)
        {
            try self.sendQueue(@intCast(self.frame_queue_len));
        }

        self.frame_queue[self.frame_queue_len] = frame.*;
        self.frame_queue_len += 1;
        self.currentQueueLength += frame_length;

        if (priority == .High) {
            try self.sendQueue(1);
        }
    }

    pub fn sendQueue(self: *Framer, count: u32) !void {
        try self.timings.start("queue_send");
        defer self.timings.end("queue_send");

        if (count == 0 or self.frame_queue_len == 0) return;

        const actual_count = @min(count, @as(u32, @intCast(self.frame_queue_len)));
        var frameset = FrameSet.init(self.outputSequence, self.frame_queue[0..actual_count]);

        const frames_copy = try self.allocator.alloc(Frame, actual_count);
        @memcpy(frames_copy, self.frame_queue[0..actual_count]);

        if (self.output_backup.get(self.outputSequence)) |old_frames| {
            self.allocator.free(old_frames);
        }
        try self.output_backup.put(self.outputSequence, frames_copy);

        const serialized = try frameset.serialize();

        if (self.client.debug) std.debug.print("Sending queue with {d} frames, size: {d}\n", .{ actual_count, serialized.len });
        try self.client.send(serialized);

        self.outputSequence +%= 1;

        var removed_length: usize = 0;
        for (self.frame_queue[0..actual_count]) |f| {
            removed_length += f.getByteLength();
        }
        self.currentQueueLength -= removed_length;

        if (actual_count < self.frame_queue_len) {
            const remaining = self.frame_queue_len - actual_count;
            @memcpy(self.frame_queue[0..remaining], self.frame_queue[actual_count..self.frame_queue_len]);
            self.frame_queue_len = remaining;
        } else {
            self.frame_queue_len = 0;
        }
    }
};
