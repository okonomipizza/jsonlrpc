const std = @import("std");
const posix = std.posix;
const net = std.net;
const jsonlrpc = @import("jsonlrpc");
const ResponseObject = jsonlrpc.ResponseObject;
const RequestObject = jsonlrpc.RequestObject;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try jsonlrpc.Server.init(allocator, 4096, handleEchoMessage);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try server.run(address);
    std.debug.print("STOPPED\n", .{});
}

fn handleEchoMessage(client: *jsonlrpc.Client, allocator: std.mem.Allocator, messege: []const u8) !?[]u8 {
    _ = client;
    std.debug.print("Got: {s}\n", .{messege});

    var request = try RequestObject.fromSlice(allocator, messege);
    defer request.deinit();

    const id = request.getId();
    const method = try request.getMethod();
    if (id != null and method != null) {
        var response_obj = try ResponseObject.newSuccess(allocator, jsonlrpc.JsonRpcVersion.v2, std.json.Value{ .string = method.? }, id.?);
        defer response_obj.deinit();
        return try response_obj.serialize(allocator);
    }

    return null;
}
