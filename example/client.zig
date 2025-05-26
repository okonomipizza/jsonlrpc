const std = @import("std");
const posix = std.posix;
const jsonlrpc = @import("jsonlrpc");
const RpcClient = jsonlrpc.RpcClient;
const RequestObject = jsonlrpc.RequestObject;
const MaybeBatch = jsonlrpc.MaybeBatch;
const json = std.json;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);

    var client = try RpcClient.init(allocator, address);

    var request = try RequestObject.init("call", null, json.Value{ .integer = 1 });
    defer request.deinit();
    const batch = MaybeBatch(RequestObject).fromSingle(request);

    const response_batch = try client.call(batch);
    if (response_batch) |response| {
        response.print();
    }
}
