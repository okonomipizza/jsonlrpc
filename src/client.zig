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
    pub fn call(self: *Self, request: RequestObject) !ResponseObject {
        const allocator = self.arena.allocator();

        const serialized_req = try request.serialize(allocator);
        try self.stream.writeBuf(serialized_req);

        // Read raw binary response from server.
        const raw_response = try self.stream.readBuf();
        // Deserialize the raw data into a structured response object.
        const response_obj = try ResponseObject.fromSlice(allocator, raw_response);

        return response_obj;
    }
};
