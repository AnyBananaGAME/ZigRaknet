//! Root module for the RakNet implementation in Zig
//! This module serves as the main entry point for the library, re-exporting
//! the core components needed by users of this RakNet implementation.

const std = @import("std");
const Client = @import("./client/client.zig").Client;
const Framer = @import("./client/framer.zig").Framer;
const Frame = @import("./proto/types/frame.zig").Frame;

/// Re-export of the main RakNet client implementation
pub const RaknetClient = Client;

/// Re-export of the RakNet packet framing functionality
pub const RaknetFramer = Framer;

/// Re-export of the RakNet frame type for packet structure
pub const RaknetFrame = Frame;

// Basic sanity test
test "simple test" {
    try std.testing.expect(true);
}
