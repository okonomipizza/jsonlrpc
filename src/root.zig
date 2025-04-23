// JSON-RPC 2.0 Specification
// https://www.jsonrpc.org/specification

pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;
pub const JsonRpcVersion = @import("type.zig").JsonRpcVersion;

pub const RpcClient = @import("client.zig").RpcClient;

pub const Server = @import("server.zig").Server;
pub const Client = @import("server.zig").Client;

const std = @import("std");

fn handleEchoMessage(client: *Client, allocator: std.mem.Allocator, messeges: []const []const u8) !?[]ResponseObject {
    _ = client;

    var requests = std.ArrayList(RequestObject).init(allocator);
    defer {
        for (requests.items) |*req| {
            req.deinit();
        }
        requests.deinit();
    }

    for (messeges) |msg| {
        const request = try RequestObject.fromSlice(allocator, msg);
        try requests.append(request);
    }

    var responses = std.ArrayList(ResponseObject).init(allocator);
    errdefer {
        for (responses.items) |*resp| {
            resp.deinit();
        }
        responses.deinit();
    }

    for (requests.items) |request| {
        const id = request.getId();
        const method = try request.getMethod();

        if (id == null or id.? == .null) {
            continue;
        }

        if (method != null) {
            const response = try ResponseObject.newSuccess(allocator, JsonRpcVersion.v2, std.json.Value{ .string = method.? }, id.?);
            try responses.append(response);
        }
    }

    if (responses.items.len > 0) {
        return try responses.toOwnedSlice();
    }

    for (responses.items) |*resp| {
        resp.deinit();
    }
    responses.deinit();

    return null;
}

const testing = std.testing;
const posix = std.posix;

test "request" {
    var thread = try std.Thread.spawn(.{}, serverThreadFn, .{});

    std.time.sleep(std.time.ns_per_s);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const socket = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());

    var client = try RpcClient.init(allocator, socket);
    defer client.deinit();

    var request = try RequestObject.init(allocator, JsonRpcVersion.v2, "foo", null, std.json.Value{ .integer = 1 });
    defer request.deinit();

    const response = try client.call(request);

    const expected_response = "{\"jsonrpc\":\"2.0\",\"result\":\"foo\",\"id\":1}";
    var expected_responses = try testing.allocator.alloc([]u8, 1);
    expected_responses[0] = try testing.allocator.dupe(u8, expected_response);

    defer {
        testing.allocator.free(expected_responses[0]);
        testing.allocator.free(expected_responses);
    }
    try testing.expectEqualStrings(expected_responses[0], response[0]);

    thread.detach();
}

test "notification" {
    var thread = try std.Thread.spawn(.{}, serverThreadFn, .{});

    std.time.sleep(std.time.ns_per_s);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const socket = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());

    var client = try RpcClient.init(allocator, socket);
    defer client.deinit();

    // Create a list of requests with null IDs
    var requests = std.ArrayList(*RequestObject).init(allocator);
    defer {
        // Clean up all request objects
        for (requests.items) |req| {
            req.deinit();
            allocator.destroy(req);
        }
        requests.deinit();
    }

    const num_requests = 100;
    for (0..num_requests) |i| {
        const req = try allocator.create(RequestObject);
        errdefer allocator.destroy(req);

        // Create method name with index
        var method_buf: [20]u8 = undefined;
        const method_name = try std.fmt.bufPrint(&method_buf, "notify{d}", .{i});

        // Initialize with null ID
        req.* = try RequestObject.init(allocator, JsonRpcVersion.v2, method_name, null, std.json.Value{ .null = {} });
        try requests.append(req);
    }

    try client.cast(requests.items);

    thread.detach();
}

test "batch request" {
    var thread = try std.Thread.spawn(.{}, serverThreadFn, .{});

    std.time.sleep(std.time.ns_per_s);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const socket = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());

    var client = try RpcClient.init(allocator, socket);
    defer client.deinit();

    // Create 3 different requests
    var request1 = try RequestObject.init(allocator, JsonRpcVersion.v2, "method1", null, std.json.Value{ .integer = 1 });
    defer request1.deinit();

    var request2 = try RequestObject.init(allocator, JsonRpcVersion.v2, "method2", null, std.json.Value{ .null = {} });
    defer request2.deinit();

    var request3 = try RequestObject.init(allocator, JsonRpcVersion.v2, "method3", null, std.json.Value{ .integer = 3 });
    defer request3.deinit();

    // Create an array of requests for batch processing
    var requests = std.ArrayList(*RequestObject).init(allocator);
    defer requests.deinit();

    try requests.append(&request1);
    try requests.append(&request2);
    try requests.append(&request3);

    // Call batch method
    const responses = try client.call(requests.items);
    defer {
        for (responses) |response| {
            allocator.free(response);
        }
        allocator.free(responses);
    }

    // Expected responses
    const expected_response1 = "{\"jsonrpc\":\"2.0\",\"result\":\"method1\",\"id\":1}";
    const expected_response2 = "{\"jsonrpc\":\"2.0\",\"result\":\"method3\",\"id\":3}";

    var expected_responses = try testing.allocator.alloc([]u8, 2);
    expected_responses[0] = try testing.allocator.dupe(u8, expected_response1);
    expected_responses[1] = try testing.allocator.dupe(u8, expected_response2);

    defer {
        for (expected_responses) |response| {
            testing.allocator.free(response);
        }
        testing.allocator.free(expected_responses);
    }

    // Verify responses
    try testing.expectEqual(2, responses.len);
    try testing.expectEqualStrings(expected_responses[0], responses[0]);
    try testing.expectEqualStrings(expected_responses[1], responses[1]);

    thread.detach();
}

fn serverThreadFn() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = Server.init(allocator, 4096, handleEchoMessage) catch {
        return;
    };
    defer server.deinit();

    const address = std.net.Address.parseIp("127.0.0.1", 5882) catch {
        return;
    };

    server.run(address) catch {
        return;
    };

    std.debug.print("STOPPED\n", .{});
}
