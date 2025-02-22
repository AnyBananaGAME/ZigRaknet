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
    InvalidFrame,
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
    mutex: std.Thread.Mutex,
    frame_pool: std.ArrayList(Frame),
    chunk_buffer: []u8,

    pub fn init(client: *Client) !Framer {
        const allocator = std.heap.page_allocator;
        const split_buffer = try BinaryStream.init(null, 0);
        const chunk_buffer = try allocator.alloc(u8, 1500 * 32);

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
            .mutex = std.Thread.Mutex{},
            .frame_pool = std.ArrayList(Frame).initCapacity(allocator, 32) catch unreachable,
            .chunk_buffer = chunk_buffer,
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
                self.client.connected = true;
                self.client.emitter.emit("connect", "");
            },
            0x15 => {
                std.debug.print("\nReceived Disconnect {any}\n", .{msg});
                self.client.socket.deinit();
            },
            else => {
                if (self.client.debug) std.debug.print("\n\nIncoming batch Unknown packet: {any}\n\n", .{msg[0]});
            },
        }
    }

    pub fn tick(self: *Framer) !void {
        self.tickCount += 1;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const size = self.receivedFrameSequences.count();
        if (size == 0) return;

        var sequences = try std.ArrayList(u32).initCapacity(self.allocator, size);
        defer sequences.deinit();

        if (self.tickCount % 50 == 0) {
            var ping = ConnectedPing.ConnectedPing.init();
            const serialized = try ping.serialize();
            var frame = frameIn(serialized);
            try self.sendFrame(&frame);
        }

        var it = self.receivedFrameSequences.keyIterator();
        while (it.next()) |key| {
            try sequences.append(key.*);
        }

        var ack = try Ack.init(sequences.items);
        self.receivedFrameSequences.clearAndFree();
        const serialized = try ack.serialize();
        try self.client.send(serialized);
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
        const frameSet = try FrameSet.deserialize(msg);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const lastInputSeqUnsigned = if (self.lastInputSequence < 0) 
            0 
        else 
            @as(u32, @intCast(self.lastInputSequence));

        if (self.receivedFrameSequences.contains(frameSet.sequence)) {
            if (self.client.debug) std.debug.print("Dropping duplicate frameset with sequence {any}\n", .{frameSet.sequence});
            return;
        }

        if (self.lostFrameSequences.contains(frameSet.sequence)) {
            _ = self.lostFrameSequences.remove(frameSet.sequence);
        }

        try self.receivedFrameSequences.put(frameSet.sequence, {});

        if (frameSet.sequence == lastInputSeqUnsigned + 1) {
            if (self.client.debug) std.debug.print("Processing in-order frameset with sequence {any}\n", .{frameSet.sequence});
            self.lastInputSequence = @intCast(frameSet.sequence);
            
            for (frameSet.frames) |frame| {
                try self.handleFrameInternal(frame);
            }
            
            var nextSeq = frameSet.sequence + 1;
            while (self.receivedFrameSequences.contains(nextSeq)) {
                nextSeq += 1;
                self.lastInputSequence = @intCast(nextSeq - 1);
            }
        } else if (frameSet.sequence > lastInputSeqUnsigned + 1) {
            if (self.client.debug) std.debug.print("Buffering out-of-order frameset with sequence {any}, expecting {any}\n", .{frameSet.sequence, lastInputSeqUnsigned + 1});
            
            // Emit drop_frameset for out-of-order frames that we're buffering
            self.client.emitter.emit("drop_frameset", "");
            
            var index = lastInputSeqUnsigned + 1;
            while (index < frameSet.sequence) : (index += 1) {
                try self.lostFrameSequences.put(index, {});
            }
            
            for (frameSet.frames) |frame| {
                try self.handleFrameInternal(frame);
            }
        }

        if (frameSet.sequence > std.math.maxInt(i32)) {
            self.lastInputSequence = 0;
        }
    }

    fn handleFrameInternal(self: *Framer, frame: Frame) FramerError!void {
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
            if (frame.sequence_frame_index.? < self.inputHighestSequenceIndex[channel] or 
                frame.ordered_frame_index.? < try self.getInputIndex(channel)) {
                return;
            }
            self.inputHighestSequenceIndex[channel] = frame.sequence_frame_index.? + 1;
            try self.incomingBatch(frame.payload);
            return;
        }

        const currentIndex = try self.getInputIndex(channel);
        if (frame.ordered_frame_index.? == currentIndex) {
            try self.processOrderedFrame(frame, channel, currentIndex);
        } else if (frame.ordered_frame_index.? > currentIndex) {
            try self.queueOrderedFrame(frame, channel);
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
            var index: u32 = currentIndex + 1;
            var processed: u32 = 0;
            const max_process = 32;
            
            var to_process = std.BoundedArray(Frame, 32){};
            
            while (processed < max_process) : (processed += 1) {
                if (outOfOrderQueue.get(index)) |framePtr| {
                    to_process.append(framePtr) catch break;
                    _ = outOfOrderQueue.remove(index);
                    index += 1;
                } else break;
            }
            
            for (to_process.slice()) |framePtr| {
                try self.incomingBatch(framePtr.payload);
            }
            
            try self.setInputIndex(channel, index);
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

    fn handleSplitInternal(self: *Framer, frame: Frame) FramerError!void {
        if (frame.split_id == null) return error.InvalidFrame;
        if (frame.split_size == null) return error.InvalidFrame;
        if (frame.split_frame_index == null) return error.InvalidFrame;
        
        const splitId = frame.split_id.?;
        
        var fragment_map = if (self.fragmentsQueue.getPtr(splitId)) |map|
            map
        else blk: {
            var new_map = FragmentMap.init(self.allocator);
            try self.fragmentsQueue.put(splitId, new_map);
            break :blk &new_map;
        };

        try fragment_map.put(frame.split_frame_index.?, frame);

        if (fragment_map.count() == frame.split_size.?) {
            try self.processSplitFrame(frame, fragment_map);
            _ = self.fragmentsQueue.remove(splitId);
        }
    }

    pub fn handleSplit(self: *Framer, frame: Frame) FramerError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.handleSplitInternal(frame);
    }

    fn processSplitFrame(self: *Framer, frame: Frame, fragment_map: *FragmentMap) !void {
        if (frame.split_size == null) return error.InvalidFrame;
        
        self.split_buffer.reset();
        
        var i: u32 = 0;
        while (i < frame.split_size.?) : (i += 1) {
            const sframe = fragment_map.get(i) orelse return error.MissingFragment;
            try self.split_buffer.write(sframe.payload);
        }

        const nFrame = Frame.init(
            frame.reliable_frame_index,
            frame.sequence_frame_index,
            frame.ordered_frame_index,
            frame.order_channel,
            frame.reliability,
            try self.split_buffer.getBytes(),
            null,
            null,
            null
        );
        try self.handleFrameInternal(nFrame);
    }

    pub fn deinit(self: *Framer) void {
        self.outputFrames.deinit();
        self.receivedFrameSequences.deinit();
        self.lostFrameSequences.deinit();
        self.inputOrderIndex.deinit();
        self.frame_pool.deinit();
        self.allocator.free(self.chunk_buffer);

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
            
            var nFrame = if (self.frame_pool.items.len > 0)
                self.frame_pool.pop()
            else
                Frame.init(
                    frame.reliable_frame_index,
                    frame.sequence_frame_index,
                    frame.ordered_frame_index,
                    frame.order_channel,
                    frame.reliability,
                    self.chunk_buffer[offset..][0..chunk_len],
                    @intCast(chunk_index),
                    splitId,
                    @intCast(splitSize)
                );

            try self.queueFrame(&nFrame, .High);
        }

        if (self.frame_pool.items.len > 128) {
            self.frame_pool.shrinkRetainingCapacity(64);
        }
    }

    pub fn queueFrame(self: *Framer, frame: *Frame, priority: Priority) !void {
        const frame_length = frame.getByteLength();
        
        if (self.currentQueueLength + frame_length > self.client.mtu_size - 36) {
            const count = @as(u32, @intCast(self.outputFrames.items.len));
            try self.sendQueue(count);
        }

        try self.outputFrames.append(frame.*);
        self.currentQueueLength += frame_length;

        if (priority == .High) {
            try self.sendQueue(1);
        }
    }

    pub fn sendQueue(self: *Framer, count: u32) !void {
        if (count == 0 or self.outputFrames.items.len == 0) return;

        const actual_count = @min(count, @as(u32, @intCast(self.outputFrames.items.len)));
        var frameset = FrameSet.init(self.outputSequence, self.outputFrames.items[0..actual_count]);
        
        const frames_copy = try self.allocator.dupe(Frame, frameset.frames);
        try self.output_backup.put(self.outputSequence, frames_copy);
        
        const serialized = try frameset.serialize();
        try self.client.send(serialized);
        self.outputSequence += 1;

        var removed_length: usize = 0;
        for (self.outputFrames.items[0..actual_count]) |f| {
            removed_length += f.getByteLength();
        }
        self.currentQueueLength -= removed_length;

        if (actual_count == self.outputFrames.items.len) {
            self.outputFrames.clearRetainingCapacity();
        } else {
            try self.outputFrames.replaceRange(0, actual_count, &.{});
        }
    }
};
