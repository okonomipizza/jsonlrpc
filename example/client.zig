const std = @import("std");
const posix = std.posix;
const jsonlrpc = @import("jsonlrpc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Connect to a JSON-RPC server.
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const socket = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());

    var client = try jsonlrpc.RpcClient.init(allocator, socket);
    defer client.deinit();

    // Send a request to the server.
    var request = try jsonlrpc.RequestObject.init(allocator, jsonlrpc.JsonRpcVersion.v2, "foo", null, std.json.Value{ .integer = 1 });
    defer request.deinit();
    const response = try client.call(request);

    std.debug.print("Response: {s}\n", .{response});
}
