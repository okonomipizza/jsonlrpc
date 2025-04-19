// JSON-RPC 2.0 Specification
// https://www.jsonrpc.org/specification

// Tests will be written in here
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;
pub const JsonRpcVersion = @import("type.zig").JsonRpcVersion;

pub const JsonStream = @import("io.zig").JsonStream;

pub const RpcClient = @import("client.zig").RpcClient;

pub const Server = @import("server.zig").Server;
pub const Client = @import("server.zig").Client;

const std = @import("std");

fn handleEchoMessage(client: *Client, allocator: std.mem.Allocator, messege: []const u8) !?[]u8 {
    _ = client;

    var request = try RequestObject.fromSlice(allocator, messege);
    defer request.deinit();

    const id = request.getId();
    const method = try request.getMethod();
    if (id != null and method != null) {
        var response_obj = try ResponseObject.newSuccess(allocator, JsonRpcVersion.v2, std.json.Value{ .string = method.? }, id.?);
        defer response_obj.deinit();
        return try response_obj.serialize(allocator);
    }

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
    try testing.expectEqualStrings(expected_response, response);

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
