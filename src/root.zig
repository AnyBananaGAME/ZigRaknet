const std = @import("std");
const napigen = @import("napigen");
const Client = @import("./client/client.zig").Client;

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn createClient() ?*Client {
    const allocator = std.heap.page_allocator;
    const client = allocator.create(Client) catch return null;
    client.* = Client.init("127.0.0.1", 19132) catch {
        allocator.destroy(client);
        return null;
    };
    return client;
}
export fn clientConnect(client: ?*Client) bool {
    if (client) |c| {
        c.connect() catch return false;
        return true;
    }
    return false;
}

export fn clientIsConnected(client: ?*Client) bool {
    if (client) |c| {
        _ = c;
        return true;
        // return c.isConnected();
    }
    return false;
}
export fn destroyClient(client: ?*Client) void {
    if (client) |c| {
        c.deinit();
        std.heap.page_allocator.destroy(c);
    }
}
comptime {
    napigen.defineModule(initModule);
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) anyerror!napigen.napi_value {
    try js.setNamedProperty(exports, "add", try js.createFunction(add));
    try js.setNamedProperty(exports, "clientConnect", try js.createFunction(clientConnect));
    try js.setNamedProperty(exports, "clientIsConnected", try js.createFunction(clientIsConnected));
    try js.setNamedProperty(exports, "destroyClient", try js.createFunction(destroyClient));
    try js.setNamedProperty(exports, "createClient", try js.createFunction(createClient));
    return exports;
}
