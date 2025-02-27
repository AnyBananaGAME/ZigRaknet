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

export fn setDebug(js: *napigen.JsContext, client_val: napigen.napi_value, value: bool) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch {
        return js.createBoolean(false) catch return null;
    };
    client.setDebug(value);
    return js.createBoolean(true) catch return null;
}

export fn getDebug(js: *napigen.JsContext, client_val: napigen.napi_value) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch {
        return js.createBoolean(false) catch return null;
    };
    return js.createBoolean(client.debug) catch return null;
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

export fn on(js: *napigen.JsContext, client_val: napigen.napi_value, event: napigen.napi_value, callback: napigen.napi_value) callconv(.C) napigen.napi_value {
    const client = js.unwrap(Client, client_val) catch |err| {
        std.debug.print("Failed to unwrap client: {}\n", .{err});
        return js.createBoolean(false) catch return null;
    };

    const event_str_raw = js.readString(event) catch |err| {
        if (client.debug) std.debug.print("Failed to read event string: {}\n", .{err});
        return js.createBoolean(false) catch return null;
    };
    if (client.debug) std.debug.print("Registering event: '{s}'\n", .{event_str_raw});

    const allocator = std.heap.page_allocator;
    const event_str = allocator.dupe(u8, event_str_raw) catch |err| {
        if (client.debug) std.debug.print("Failed to dupe event string: {}\n", .{err});
        return js.createBoolean(false) catch return null;
    };

    var ref: napigen.napi_ref = undefined;
    napigen.check(napigen.napi_create_reference(js.env, callback, 1, &ref)) catch |err| {
        if (client.debug) std.debug.print("Failed to create callback reference: {}\n", .{err});
        allocator.free(event_str);
        return js.createBoolean(false) catch return null;
    };

    const handler_ptr = allocator.create(EventHandler) catch |err| {
        if (client.debug) std.debug.print("Failed to allocate Handler: {}\n", .{err});
        _ = napigen.napi_delete_reference(js.env, ref);
        allocator.free(event_str);
        return js.createBoolean(false) catch return null;
    };
    handler_ptr.* = EventHandler.init(js.env, ref, client.debug) catch |err| {
        if (client.debug) std.debug.print("Failed to initialize Handler: {}\n", .{err});
        allocator.destroy(handler_ptr);
        _ = napigen.napi_delete_reference(js.env, ref);
        allocator.free(event_str);
        return js.createBoolean(false) catch return null;
    };

    const HandlerCleanupContext = struct {
        event_str: []const u8,
        handler: *EventHandler,
        allocator: std.mem.Allocator,
    };

    const cleanup_fn = struct {
        fn cleanup(ctx: *anyopaque) void {
            const self = @as(*HandlerCleanupContext, @ptrCast(@alignCast(ctx)));
            self.handler.deinit();
            _ = napigen.napi_delete_reference(self.handler.env, self.handler.ref);
            self.allocator.destroy(self.handler);
            self.allocator.free(self.event_str);
            self.allocator.destroy(self);
        }
    }.cleanup;

    const cleanup_ctx = allocator.create(HandlerCleanupContext) catch |err| {
        if (client.debug) std.debug.print("Failed to create cleanup context: {}\n", .{err});
        handler_ptr.deinit();
        allocator.destroy(handler_ptr);
        _ = napigen.napi_delete_reference(js.env, ref);
        allocator.free(event_str);
        return js.createBoolean(false) catch return null;
    };
    cleanup_ctx.* = .{
        .event_str = event_str,
        .handler = handler_ptr,
        .allocator = allocator,
    };

    const bound_fn = struct {
        fn handleEvent(ctx: *const anyopaque, msg: []const u8) void {
            const handler_ctx = @as(*const EventHandler, @ptrCast(@alignCast(ctx)));
            if (handler_ctx.debug) std.debug.print("handleEvent invoked with msg len: {d}\n", .{msg.len});
            handler_ctx.handle(msg);
            if (handler_ctx.debug) std.debug.print("handleEvent finished\n", .{});
        }
    }.handleEvent;

    const dummy_context = handler_ptr;  
    if (client.emitter.onWithContext(event_str, @ptrCast(dummy_context), bound_fn, cleanup_fn)) |_| {
        return js.createBoolean(true) catch return null;
    } else |err| {
        if (client.debug) std.debug.print("Failed to register handler: {}\n", .{err});
        cleanup_fn(@ptrCast(cleanup_ctx));
        return js.createBoolean(false) catch return null;
    }
}

const EventHandler = struct {
    ref: napigen.napi_ref,
    env: napigen.napi_env,
    async_work: napigen.napi_async_work,
    tsfn: napigen.napi_threadsafe_function,
    debug: bool,

    pub fn init(env: napigen.napi_env, callback_ref: napigen.napi_ref, debug: bool) !EventHandler {
        var tsfn: napigen.napi_threadsafe_function = undefined;
        const tsfn_name = "eventCallback";
        
        var name_value: napigen.napi_value = undefined;
        try napigen.check(napigen.napi_create_string_utf8(env, tsfn_name, tsfn_name.len, &name_value));
        
        try napigen.check(napigen.napi_create_threadsafe_function(
            env,
            null,
            null,
            name_value,
            0,
            1,
            null,
            null,
            null,
            callJs,
            &tsfn,
        ));

        return EventHandler{
            .ref = callback_ref,
            .env = env,
            .async_work = undefined,
            .tsfn = tsfn,
            .debug = debug,
        };
    }

    const CallContext = struct {
        data: []const u8,
        ref: napigen.napi_ref,
        env: napigen.napi_env,
        debug: bool,
    };

    fn callJs(env: napigen.napi_env, js_callback: napigen.napi_value, context: ?*anyopaque, data: ?*anyopaque) callconv(.C) void {
        _ = js_callback; // autofix
        _ = context; // autofix
        const call_ctx = @as(*CallContext, @ptrCast(@alignCast(data.?)));
        defer std.heap.page_allocator.destroy(call_ctx);

        var scope: napigen.napi_handle_scope = undefined;
        if (napigen.napi_open_handle_scope(env, &scope) != napigen.napi_ok) {
            if (call_ctx.debug) std.debug.print("Failed to open handle scope\n", .{});
            return;
        }
        defer _ = napigen.napi_close_handle_scope(env, scope);

        var global: napigen.napi_value = undefined;
        if (napigen.napi_get_global(env, &global) != napigen.napi_ok) {
            if (call_ctx.debug) std.debug.print("Failed to get global object\n", .{});
            return;
        }

        var callback_val: napigen.napi_value = undefined;
        if (napigen.napi_get_reference_value(call_ctx.env, call_ctx.ref, &callback_val) != napigen.napi_ok) {
            if (call_ctx.debug) std.debug.print("Failed to get callback reference\n", .{});
            return;
        }

        var buffer: napigen.napi_value = undefined;
        if (napigen.napi_create_buffer_copy(env, call_ctx.data.len, @ptrCast(call_ctx.data.ptr), null, &buffer) != napigen.napi_ok) {
            if (call_ctx.debug) std.debug.print("Failed to create buffer\n", .{});
            return;
        }

        var result: napigen.napi_value = undefined;
        if (napigen.napi_call_function(env, global, callback_val, 1, &buffer, &result) != napigen.napi_ok) {
            if (call_ctx.debug) std.debug.print("Failed to call JS callback\n", .{});
            return;
        }
    }

    pub fn handle(self: *const @This(), msg: []const u8) void {
        if (self.debug) std.debug.print("Handler.handle called on thread: {d} with msg len: {d}\n", .{std.Thread.getCurrentId(), msg.len});
        
        const ctx_allocator = std.heap.page_allocator;
        const ctx = ctx_allocator.create(CallContext) catch |err| {
            if (self.debug) std.debug.print("Failed to create call context: {}\n", .{err});
            return;
        };
        ctx.* = .{
            .data = msg,
            .ref = self.ref,
            .env = self.env,
            .debug = self.debug,
        };

        if (napigen.napi_call_threadsafe_function(self.tsfn, ctx, napigen.napi_tsfn_nonblocking) != napigen.napi_ok) {
            if (self.debug) std.debug.print("Failed to call threadsafe function\n", .{});
            ctx_allocator.destroy(ctx);
            return;
        }
    }

    pub fn deinit(self: *const @This()) void {
        _ = napigen.napi_release_threadsafe_function(self.tsfn, napigen.napi_tsfn_release);
    }
};

comptime {
    napigen.defineModule(initModule);
}

fn initModule(js: *napigen.JsContext, exports: napigen.napi_value) anyerror!napigen.napi_value {
    try js.setNamedProperty(exports, "add", try js.createFunction(add));
    try js.setNamedProperty(exports, "connect", try js.createFunction(connect));
    try js.setNamedProperty(exports, "isConnected", try js.createFunction(isConnected));
    try js.setNamedProperty(exports, "setDebug", try js.createFunction(setDebug));
    try js.setNamedProperty(exports, "getDebug", try js.createFunction(getDebug));
    try js.setNamedProperty(exports, "destroyClient", try js.createFunction(destroyClient));
    try js.setNamedProperty(exports, "createClient", try js.createFunction(createClient));
    try js.setNamedProperty(exports, "sendData", try js.createFunction(sendData));
    try js.setNamedProperty(exports, "on", try js.createFunction(on));
    return exports;
}
