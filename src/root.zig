const std = @import("std");
const napigen = @import("napigen");
const Client = @import("./client/client.zig").Client;
const Framer = @import("./client/framer.zig").Framer;
const Frame = @import("./proto/types/frame.zig").Frame;

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn createClient(js: *napigen.JsContext, host: napigen.napi_value, port: u16) callconv(.C) napigen.napi_value {
    const allocator = std.heap.page_allocator;
    
    // Convert napi_value to string
    const host_str = js.readString(host) catch {
        return js.null() catch return null;
    };
    
    const client = allocator.create(Client) catch {
        return js.null() catch return null;
    };
    
    client.* = Client.init(host_str, port) catch {
        allocator.destroy(client);
        return js.null() catch return null;
    };
    
    return js.wrapPtr(client) catch return null;
}

export fn connect(js: *napigen.JsContext, client_val: napigen.napi_value) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch {
        return js.createBoolean(false) catch return null;
    };
    
    const result = client.connect() catch {
        return js.createBoolean(false) catch return null;
    };
    _ = result;
    
    return js.createBoolean(true) catch return null;
}

export fn isConnected(js: *napigen.JsContext, client_val: napigen.napi_value) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch {
        return js.createBoolean(false) catch return null;
    };
    return js.createBoolean(client.connected) catch return null;
}

export fn sendData(js: *napigen.JsContext, client_val: napigen.napi_value, buffer: napigen.napi_value) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch {
        return js.createBoolean(false) catch return null;
    };

    var buffer_data: ?*anyopaque = undefined;
    var buffer_len: usize = undefined;
    if (napigen.napi_get_buffer_info(js.env, buffer, &buffer_data, &buffer_len) != napigen.napi_ok) {
        return js.createBoolean(false) catch return null;
    }

    const data_slice = @as([*]u8, @ptrCast(buffer_data.?))[0..buffer_len];
    
    const allocator = std.heap.page_allocator;
    const frame_ptr = allocator.create(Frame) catch {
        return js.createBoolean(false) catch return null;
    };
    frame_ptr.* = Framer.frameIn(data_slice);

    client.framer.?.sendFrame(frame_ptr) catch {
        allocator.destroy(frame_ptr);
        return js.createBoolean(false) catch return null;
    };

    allocator.destroy(frame_ptr);
    return js.createBoolean(true) catch return null;
}

export fn destroyClient(js: *napigen.JsContext, client_val: napigen.napi_value) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch {
        return js.undefined() catch return null;
    };
    client.deinit();
    std.heap.page_allocator.destroy(client);
    
    return js.undefined() catch return null;
}

comptime {
    napigen.defineModule(initModule);
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) anyerror!napigen.napi_value {
    try js.setNamedProperty(exports, "add", try js.createFunction(add));
    try js.setNamedProperty(exports, "connect", try js.createFunction(connect));
    try js.setNamedProperty(exports, "isConnected", try js.createFunction(isConnected));
    try js.setNamedProperty(exports, "destroyClient", try js.createFunction(destroyClient));
    try js.setNamedProperty(exports, "createClient", try js.createFunction(createClient));
    try js.setNamedProperty(exports, "sendData", try js.createFunction(sendData));
    return exports;
}
