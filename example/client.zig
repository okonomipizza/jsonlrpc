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

    // Send a request to the server.
    const request = jsonlrpc.RequestObject{
        .jsonrpc = jsonlrpc.JsonRpcVersion.v2,
        .id = std.json.Value{ .integer = 1 },
        .method = "foo",
        .params = null,
    };

    const serialized_req = try request.serialize(allocator);
    try write(socket, serialized_req);
}

fn write(socket: posix.socket_t, msg: []const u8) !void {
    var pos: usize = 0;
    while (pos < msg.len) {
        const written = try posix.write(socket, msg[pos..]);
        if (written == 0) {
            return error.Closed;
        }
        pos += written;
    }
}
