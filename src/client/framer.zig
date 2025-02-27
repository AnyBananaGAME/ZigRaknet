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
    frame_arena: std.heap.ArenaAllocator,
    chunk_buffer: []u8,
    debug: bool = false,
    serialize_buffer: std.ArrayList(u8),

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
            .frame_arena = std.heap.ArenaAllocator.init(allocator),
            .chunk_buffer = chunk_buffer,
            .debug = client.debug,
            .serialize_buffer = std.ArrayList(u8).initCapacity(allocator, 1500) catch unreachable,
        };
    }

    pub fn incomingBatch(self: *Framer, msg: []const u8) !void {
        if (self.client.debug) std.debug.print("Received packet type: {d}\n", .{msg[0]});
        switch (msg[0]) {
            ConnectedPing.ID => {
                const data = try ConnectedPing.ConnectedPing.deserialize(msg);
                if (self.client.debug) std.debug.print("\n\nIncoming ConnectedPing: {any}\n\n", .{data});
                var pong = ConnectedPong.ConnectedPong.init(data.timestamp);
                const serialized = try pong.serialize();
                var frame = frameIn(serialized);
                try self.sendFrame(&frame);
            },
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
                const connect_msg = try std.fmt.allocPrint(self.allocator, "Connected to {s}:{d}", .{self.client.host, self.client.port});
                if (self.client.debug) std.debug.print("Emitting connect event: {s}\n", .{connect_msg});
                self.client.emitter.emit("connect", connect_msg);
                self.allocator.free(connect_msg);
            },
            0x15 => {
                const disconnect_msg = try std.fmt.allocPrint(self.allocator, "Disconnected from {s}:{d}", .{self.client.host, self.client.port});
                if (self.client.debug) std.debug.print("Emitting disconnect event: {s}\n", .{disconnect_msg});
                self.client.emitter.emit("disconnect", disconnect_msg);
                self.allocator.free(disconnect_msg);
                std.debug.print("\nReceived Disconnect {any}\n", .{msg});
                self.client.socket.deinit();
            },
            254 => {
                if (self.client.debug) std.debug.print("\nReceived encapsulated message: {any}\n", .{msg});
                self.client.emitter.emit("encapsulated", msg);
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
        
        if (self.client.debug) std.debug.print("Handling FrameSet with sequence {d}, frames: {d}\n", .{
            frameSet.sequence, 
            frameSet.frames.len
        });
        
        if (frameSet.sequence <= self.lastInputSequence) {
            if (self.client.debug) std.debug.print("Dropping old frameset with sequence {d}\n", .{frameSet.sequence});
            return;
        }

        const lastInputSeqUnsigned = if (self.lastInputSequence < 0) 
            0 
        else 
            @as(u32, @intCast(self.lastInputSequence));

        if (frameSet.sequence == lastInputSeqUnsigned + 1) {
            try self.receivedFrameSequences.put(frameSet.sequence, {});
            self.lastInputSequence = @intCast(frameSet.sequence);
            
            for (frameSet.frames) |frame| {
                try self.handleFrameInternal(frame);
            }
            
            var nextSeq = frameSet.sequence +% 1;
            while (self.receivedFrameSequences.contains(nextSeq)) {
                if (self.client.debug) std.debug.print("Processing buffered frameset {d}\n", .{nextSeq});
                nextSeq +%= 1;
                self.lastInputSequence = @intCast(nextSeq -% 1);
            }
            return;
        }

        if (frameSet.sequence > lastInputSeqUnsigned + 1) {
            if (self.client.debug) std.debug.print("Buffering out-of-order frameset {d}, expecting {d}\n", .{
                frameSet.sequence, 
                lastInputSeqUnsigned + 1
            });
            
            try self.receivedFrameSequences.put(frameSet.sequence, {});
            
            var index = lastInputSeqUnsigned +% 1;
            while (index < frameSet.sequence) : (index +%= 1) {
                try self.lostFrameSequences.put(index, {});
            }
            
            for (frameSet.frames) |frame| {
                try self.handleFrameInternal(frame);
            }
        }

        if (!self.client.connected) {
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
        }
    }

    fn handleFrameInternal(self: *Framer, frame: Frame) FramerError!void {
        if (!frame.isSplit() and !frame.isSequenced() and !frame.isOrdered()) {
            try self.incomingBatch(frame.payload);
            return;
        }

        const arena = &self.frame_arena;
        defer _ = arena.reset(.free_all);

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
            const new_map = FragmentMap.init(self.allocator);
            try self.fragmentsQueue.put(splitId, new_map);
            break :blk self.fragmentsQueue.getPtr(splitId).?;
        };

        try fragment_map.put(frame.split_frame_index.?, frame);

        if (fragment_map.count() == frame.split_size.?) {
            try self.processSplitFrame(frame, fragment_map);
            if (self.fragmentsQueue.getPtr(splitId)) |map| {
                map.deinit();
            }
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
        
        self.serialize_buffer.clearRetainingCapacity();
        
        var i: u32 = 0;
        while (i < frame.split_size.?) : (i += 1) {
            const sframe = fragment_map.get(i) orelse return error.MissingFragment;
            try self.serialize_buffer.appendSlice(sframe.payload);
        }

        const payload = try self.frame_arena.allocator().dupe(u8, self.serialize_buffer.items);
        const nFrame = Frame.init(
            frame.reliable_frame_index,
            frame.sequence_frame_index, 
            frame.ordered_frame_index,
            frame.order_channel,
            frame.reliability,
            payload,
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
            
            var nFrame = Frame.init(
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

        _ = self.frame_arena.reset(.retain_capacity);
    }

    pub fn queueFrame(self: *Framer, frame: *const Frame, priority: Priority) !void {
        const frame_length = frame.getByteLength();
        
        if (self.currentQueueLength + frame_length > self.client.mtu_size - 36) {
            try self.sendQueue(@intCast(self.outputFrames.items.len));
        }

        try self.outputFrames.ensureTotalCapacity(self.outputFrames.items.len + 1);
        try self.outputFrames.append(frame.*);
        self.currentQueueLength += frame_length;

        if (priority == .High) {
            try self.sendQueue(1);
        }
    }

    pub fn sendQueue(self: *Framer, count: u32) !void {
        if (count == 0 or self.outputFrames.items.len == 0) return;

        self.serialize_buffer.clearRetainingCapacity();
        
        const actual_count = @min(count, @as(u32, @intCast(self.outputFrames.items.len)));
        var frameset = FrameSet.init(self.outputSequence, self.outputFrames.items[0..actual_count]);
        
        const frames_copy = try self.allocator.alloc(Frame, actual_count);
        @memcpy(frames_copy, self.outputFrames.items[0..actual_count]);
        
        if (self.output_backup.get(self.outputSequence)) |old_frames| {
            self.allocator.free(old_frames);
        }
        try self.output_backup.put(self.outputSequence, frames_copy);
        
        const serialized = try frameset.serialize();
        
        if (self.client.debug) std.debug.print("Sending queue with {d} frames, size: {d}\n", .{actual_count, serialized.len});
        self.client.send(serialized) catch |err| {
            if (self.client.debug) std.debug.print("Error sending queue: {any}\n", .{err});
            self.allocator.free(frames_copy);
            _ = self.output_backup.remove(self.outputSequence);
            return err;
        };
        
        self.outputSequence +%= 1;

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
