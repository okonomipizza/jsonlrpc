const std = @import("std");
const posix = std.posix;
const net = std.net;
const jsonlrpc = @import("jsonlrpc");
const ResponseObject = jsonlrpc.ResponseObject;
const RequestObject = jsonlrpc.RequestObject;
const Client = jsonlrpc.Client;
const JsonRpcVersion = jsonlrpc.JsonRpcVersion;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try jsonlrpc.Server.init(allocator, 4096, handleEchoMessage);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try server.run(address);
    std.debug.print("STOPPED\n", .{});
}

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
