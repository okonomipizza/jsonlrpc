//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const posix = std.posix;
const net = std.net;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const JsonStream = @import("io.zig").JsonStream;
const RequestObject = @import("types.zig").RequestObject;
const JsonRpcVersion = @import("types.zig").JsonRpcVersion;
const RequestId = @import("types.zig").RequestId;
const ResponseObject = @import("types.zig").ResponseObject;
const RpcClient = @import("rpc.zig").RpcClient;
const MaybeBatch = @import("types.zig").MaybeBatch;

const testing = std.testing;

test "request" {
    const allocator = testing.allocator;

    const server_info = try spawn_server_thread(allocator);
    defer {
        allocator.destroy(server_info.context.address);
        allocator.destroy(server_info.context);
        allocator.destroy(server_info);
    }

    var client = try RpcClient.init(allocator, 1024, server_info.address);
    defer client.deinit();

    const request = MaybeBatch(RequestObject){
        .single = RequestObject.init(JsonRpcVersion.v2, "echo", null, RequestId{ .number = 1 }),
    };
    const response = try client.call(request);
    defer {
        response.deinit();
        allocator.destroy(response);
    }

    const response_object = response.get(0) orelse {
        std.debug.print("No response received\n", .{});
        try std.testing.expect(false);
        return;
    };

    switch (response_object.*) {
        .ok => |res| {
            switch (res.id) {
                .number => |num| {
                    try std.testing.expectEqual(@as(i64, 1), num);
                },
                .string => |_| {
                    std.debug.print("Expected number but got string\n", .{});
                    try std.testing.expect(false);
                },
            }
            const result = res.result.?.string;
            try std.testing.expectEqualStrings("echo", result);
        },
        .err => {
            std.debug.print("Expected ok response but got err response", .{});
            try std.testing.expect(false);
        },
    }
}

test "notification" {
    const allocator = testing.allocator;

    const server_info = try spawn_server_thread(allocator);
    defer {
        allocator.destroy(server_info.context.address);
        allocator.destroy(server_info.context);
        allocator.destroy(server_info);
    }

    var client = try RpcClient.init(allocator, 1024, server_info.address);
    defer client.deinit();

    var n: usize = 0;
    while (n < 100) : (n += 1) {
        const request = RequestObject.init(JsonRpcVersion.v2, "test", null, null);
        try client.cast(request);
    }
}

test "batch_call" {
    const allocator = testing.allocator;

    const server_info = try spawn_server_thread(allocator);
    defer {
        allocator.destroy(server_info.context.address);
        allocator.destroy(server_info.context);
        allocator.destroy(server_info);
    }

    var client = try RpcClient.init(allocator, 4096, server_info.address);
    defer client.deinit();

    const request1 = RequestObject.init(JsonRpcVersion.v2, "foo", null, RequestId{ .number = 1 });
    const request2 = RequestObject.init(JsonRpcVersion.v2, "bar", null, RequestId{ .string = "2" });
    const notification = RequestObject.init(JsonRpcVersion.v2, "baz", null, null);

    var batch = std.ArrayList(RequestObject).init(allocator);
    try batch.append(request1);
    try batch.append(request2);
    try batch.append(notification);
    defer batch.deinit();

    const request = MaybeBatch(RequestObject){
        .batch = batch,
    };

    const response = try client.call(request);
    defer {
        response.deinit();

        allocator.destroy(response);
    }

    try std.testing.expectEqual(@as(usize, 2), response.len());
    const response1 = response.get(0).?;
    switch (response1.*) {
        .ok => |ok| {
            try std.testing.expectEqual(@as(i64, 1), ok.id.number);
            if (ok.result) |result| {
                try std.testing.expectEqualStrings("foo", result.string);
            } else {
                std.debug.print("Misiing result\n", .{});
                try std.testing.expect(false);
            }
        },
        .err => {
            std.debug.print("Expected ok but got err\n", .{});
        },
    }
    const response2 = response.get(1).?;
    switch (response2.*) {
        .ok => |ok| {
            try std.testing.expectEqualStrings("2", ok.id.string);
            if (ok.result) |result| {
                try std.testing.expectEqualStrings("bar", result.string);
            } else {
                std.debug.print("Misiing result\n", .{});
                try std.testing.expect(false);
            }
        },
        .err => {
            std.debug.print("Expected ok but got err\n", .{});
        },
    }
}

const ServerInfo = struct {
    thread: Thread,
    address: std.net.Address,
    context: *ServerContext,
};

const ServerContext = struct {
    address: *std.net.Address,
    allocator: std.mem.Allocator,
};

/// Spawn a server thread and returns the address
/// Caller should destroy ServerInfo
fn spawn_server_thread(allocator: Allocator) !*ServerInfo {
    const address = try allocator.create(std.net.Address);
    address.* = undefined;

    const context = try allocator.create(ServerContext);
    context.* = ServerContext{
        .address = address,
        .allocator = allocator,
    };

    // Spawn a thread
    const thread = try std.Thread.spawn(.{}, serverThread, .{context});
    // Wait a nano seconds until server activated
    std.time.sleep(100 * std.time.ns_per_ms);

    const server_info = try allocator.create(ServerInfo);
    server_info.* = ServerInfo{
        .thread = thread,
        .address = address.*,
        .context = context,
    };
    return server_info;
}

fn serverThread(context: *ServerContext) void {
    runServer(context) catch |err| {
        std.debug.print("Server error: {}\n", .{err});
    };
}

/// This server will be shutdown after response at once
fn runServer(context: *ServerContext) !void {
    const allocator = context.allocator;

    // Since we chose port: 0, OS will pick a port for us
    const address = try std.net.Address.parseIp("127.0.0.1", 0);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());

    // Get a actual address that OS picked above
    var actual_address: std.net.Address = undefined;
    var len: posix.socklen_t = @sizeOf(net.Address);
    try posix.getsockname(listener, &actual_address.any, &len);
    context.address.* = actual_address;

    try posix.listen(listener, 128);

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const client_socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            return err;
        };
        defer posix.close(client_socket);

        var buf: [4096]u8 = undefined;
        var jsonStream = JsonStream{
            .buf = &buf,
            .start = 0,
            .pos = 0,
        };
        const request_message = try jsonStream.readMessage(client_socket);

        var request_maybebatch = try MaybeBatch(RequestObject).fromSlice(allocator, request_message);
        defer request_maybebatch.deinit();

        switch (request_maybebatch) {
            .single => |request| {
                if (request.id) |id| {
                    // echo request
                    const response = ResponseObject{ .ok = .{
                        .jsonrpc = JsonRpcVersion.v2,
                        .result = std.json.Value{ .string = request.method },
                        .id = id,
                        ._parsed_data = undefined,
                    } };
                    const responseJson = try response.toJson(allocator);
                    defer allocator.free(responseJson);

                    try jsonStream.writeMessage(responseJson, client_socket);
                }
            },
            .batch => |requests| {
                var combined_response = std.ArrayList(u8).init(allocator);
                // defer combined_response.deinit();

                for (requests.items, 0..) |request, i| {
                    if (request.id) |id| {
                        const response = ResponseObject{ .ok = .{
                            .jsonrpc = JsonRpcVersion.v2,
                            .result = std.json.Value{ .string = request.method },
                            .id = id,
                            ._parsed_data = undefined,
                        } };
                        const responseJson = try response.toJson(allocator);
                        defer allocator.free(responseJson);

                        if (i > 0) {
                            try combined_response.append('\n');
                        }
                        try combined_response.appendSlice(responseJson);
                    }
                }

                const final_response = try combined_response.toOwnedSlice();
                defer allocator.free(final_response);

                try jsonStream.writeMessage(final_response, client_socket);
            },
        }
    }
}
