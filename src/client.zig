const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const JsonStream = @import("io.zig").JsonStream;
pub const MaybeBatch = @import("type.zig").MaybeBatch;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;

/// RpcClient provides a client implementation for JSON-RPC protocol communication over a tcp connection
/// It handles serialization and deserialization of requests and responses, and supports
/// both individual and batch requests.
pub const RpcClient = struct {
    socket: posix.socket_t,
    stream: JsonStream(ResponseObject, RequestObject),
    allocator: Allocator,

    pub fn init(allocator: Allocator, address: std.net.Address) !RpcClient {
        const tpe: u32 = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        const socket = try posix.socket(address.any.family, tpe, protocol);
        try posix.connect(socket, &address.any, address.getOsSockLen());

        const stream = try JsonStream(ResponseObject, RequestObject).init(allocator, socket, address, 4096);
        errdefer stream.deinit(allocator);

        return .{ .socket = socket, .stream = stream, .allocator = allocator };
    }

    pub fn deinit(self: *RpcClient) void {
        self.stream.deinit(self.allocator);
        posix.close(self.socket);
    }

    pub fn call(self: *RpcClient, request: MaybeBatch(RequestObject)) !?MaybeBatch(ResponseObject) {
        const allocator = self.allocator;

        try self.stream.writeMessage(request, null, null);

        const response = try self.stream.readMessage(allocator);

        if (response) |res| {
            res.print();
        }

        return response;
    }
};
