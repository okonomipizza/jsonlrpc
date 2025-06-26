const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const JsonStream = @import("io.zig").JsonStream;
const RequestObject = @import("types.zig").RequestObject;
const ResponseObject = @import("types.zig").ResponseObject;
const MaybeBatch = @import("types.zig").MaybeBatch;

pub const RpcClient = struct {
    // socket: std.posix.socket_t,
    address: std.net.Address,
    stream: JsonStream,
    buf: []u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, buf_size: usize, address: std.net.Address) !RpcClient {
        // const socket = try posix.socket(address.any.family, tpe, protocol);
        // try posix.connect(socket, &address.any, address.getOsSockLen());

        const buf: []u8 = try allocator.alloc(u8, buf_size);
        const stream = JsonStream.init(buf);

        return .{
            .address = address,
            .stream = stream,
            .buf = buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: RpcClient) void {
        const allocator = self.allocator;
        allocator.free(self.buf);
    }

    fn bind(self: *RpcClient) !std.posix.socket_t {
        const tpe: u32 = posix.SOCK.STREAM;
        const protocol = posix.IPPROTO.TCP;
        const socket = try posix.socket(self.address.any.family, tpe, protocol);
        try posix.connect(socket, &self.address.any, self.address.getOsSockLen());
        return socket;
    }

    pub fn call(self: *RpcClient, request: MaybeBatch(RequestObject)) !*MaybeBatch(ResponseObject) {
        const allocator = self.allocator;
        const socket = try self.bind();
        defer std.posix.close(socket);
        const response = try allocator.create(MaybeBatch(ResponseObject));

        switch (request) {
            .single => |req| {
                const requestJson = try req.toJson(allocator);
                defer allocator.free(requestJson);

                try self.stream.writeMessage(requestJson, socket);
                const responseJson = try self.stream.readMessage(socket);

                response.* = try MaybeBatch(ResponseObject).fromSlice(allocator, responseJson);

                return response;
            },
            .batch => |requests| {
                if (requests.items.len == 0) return error.EmptyRequests;

                var combined_request = std.ArrayList(u8).init(allocator);
                defer combined_request.deinit();

                for (requests.items, 0..) |req, i| {
                    const requestJson = try req.toJson(allocator);
                    defer allocator.free(requestJson);

                    if (i > 0) {
                        try combined_request.append('\n');
                    }
                    try combined_request.appendSlice(requestJson);
                }

                const final_request = try combined_request.toOwnedSlice();
                defer allocator.free(final_request);

                try self.stream.writeMessage(final_request, socket);
                const responseJson = try self.stream.readMessage(socket);

                response.* = try MaybeBatch(ResponseObject).fromSlice(allocator, responseJson);

                return response;
            },
        }
    }

    pub fn cast(self: *RpcClient, request: RequestObject) !void {
        const allocator = self.allocator;

        const socket = try self.bind();
        defer std.posix.close(socket);

        const requestJson = try request.toJson(allocator);
        defer allocator.free(requestJson);

        try self.stream.writeMessage(requestJson, socket);
    }
};
