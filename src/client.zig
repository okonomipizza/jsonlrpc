const JsonStream = @import("io.zig").JsonStream;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;
const std = @import("std");
const posix = std.posix;

pub const RpcClient = struct {
    socket: posix.socket_t,
    stream: JsonStream,
    arena: *std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !RpcClient {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const stream = try JsonStream.init(arena.allocator(), socket);

        return RpcClient{
            .socket = socket,
            .stream = stream,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stream.deinit();

        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    /// Send request to server and get response.
    pub fn call(self: *Self, request: []u8) !ResponseObject {
        const allocator = self.arena.allocator();

        try self.stream.writeBuf(request);

        // Read raw binary response from server.
        const raw_response = try self.stream.readBuf();
        // Deserialize the raw data into a structured response object.
        const response_obj = try ResponseObject.fromSlice(allocator, raw_response);

        return response_obj;
    }

    pub fn batchCall(self: *Self, requests: []RequestObject) ![]ResponseObject {
        const allocator = self.arena.allocator();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        for (requests) |req| {
            const serialized = try req.serialize(allocator);
            defer allocator.free(serialized);

            try buffer.appendSlice(serialized);
        }

        const combined_data = try buffer.toOwnedSlice();
        defer allocator.free(combined_data);

        try self.stream.write(combined_data);

        return try self.stream.readResponse(allocator);
    }
};
