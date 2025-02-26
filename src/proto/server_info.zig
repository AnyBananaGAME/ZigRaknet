const std = @import("std");

pub const ServerInfo = struct {
    type: []const u8,
    message: []const u8,
    protocol: u16,
    version: []const u8,
    playerCount: u32,
    maxPlayers: u32,
    serverName: []const u8,
    gamemode: []const u8,
};

fn cleanFormatCodes(str: []const u8) []const u8 {
    var i: usize = 0;
    while (i < str.len - 1) : (i += 1) {
        if (str[i] == 194 and str[i + 1] == 186) {
            return str[i + 2..];
        }
    }
    return str;
}

fn stripFormatCodes(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < str.len) {
        if (i + 1 < str.len and str[i] == 194 and str[i + 1] == 186) {
            i += 3;
            continue;
        }
        try result.append(str[i]);
        i += 1;
    }
    
    return try result.toOwnedSlice();
}

pub fn parseServerInfo(msg: []const u8) !ServerInfo {
    const allocator = std.heap.page_allocator;
    var parts = std.mem.split(u8, msg, ";");
    
    const type_str = parts.next() orelse return error.InvalidFormat;
    const raw_message = parts.next() orelse return error.InvalidFormat;
    const protocol_str = parts.next() orelse return error.InvalidFormat;
    const version = parts.next() orelse return error.InvalidFormat;
    const player_count_str = parts.next() orelse return error.InvalidFormat;
    const max_players_str = parts.next() orelse return error.InvalidFormat;
    _ = parts.next(); 
    const raw_server_name = parts.next() orelse return error.InvalidFormat;
    const gamemode = parts.next() orelse return error.InvalidFormat;

    const message = try stripFormatCodes(allocator, raw_message);
    const server_name = try stripFormatCodes(allocator, raw_server_name);

    return ServerInfo{
        .type = type_str,
        .message = message,
        .protocol = try std.fmt.parseInt(u16, protocol_str, 10),
        .version = version,
        .playerCount = try std.fmt.parseInt(u32, player_count_str, 10),
        .maxPlayers = try std.fmt.parseInt(u32, max_players_str, 10),
        .serverName = server_name,
        .gamemode = gamemode,
    };
} 