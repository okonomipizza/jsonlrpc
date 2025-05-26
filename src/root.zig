const std = @import("std");
const posix = std.posix;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;
pub const JsonRpcVersion = @import("type.zig").JsonRpcVersion;
pub const JsonStream = @import("io.zig").JsonStream;
pub const MaybeBatch = @import("type.zig").MaybeBatch;
pub const Reader = @import("io.zig").Reader;
pub const RpcClient = @import("client.zig").RpcClient;
pub const Client = @import("server.zig").Client;
pub const Epoll = @import("io.zig").Epoll;

// test "test" {
//     const allocator = testing.allocator;

//     const server = try spawnServer();
//     var thread = try std.Thread.spawn(.{}, runEchoServer, .{ allocator, server.listener });
//     std.time.sleep(std.time.ns_per_s);

//     var client = try RpcClient.init(allocator, server.listener, server.address);

//     const request = try RequestObject.init("call", null, std.json.Value{ .integer = 1 });
//     const batch = MaybeBatch(RequestObject).fromSingle(request);

//     const response = try client.call(batch);
//     _ = response;

//     thread.detach();
// }
