const JsonStream = @import("io.zig").JsonStream;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;
const Reader = @import("io.zig").Reader;
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

pub const RpcClient = struct {
    socket: posix.socket_t,
    reader: Reader,
    allocator: Allocator,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !RpcClient {
        // const stream = try JsonStream.init(allocator, socket);
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        return .{
            .socket = socket,
            .reader = reader,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RpcClient) void {
        self.reader.deinit(self.allocator);
    }

    /// Send request to server and get response.
    pub fn call(self: *RpcClient, request: RequestObject) ![]u8 {
        const allocator = self.allocator;

        const serialized_request = try request.serialize(allocator);
        defer allocator.free(serialized_request);

        try self.sendRequest(serialized_request);

        return try self.readResponse();
    }

    fn readResponse(self: *RpcClient) ![]u8 {
        return self.reader.readMessage(self.socket) catch |err| {
            std.debug.print("Error: {}", .{err});
            return err;
        };
    }

    fn sendRequest(self: *RpcClient, msg: []const u8) !void {
        var pos: usize = 0;
        while (pos < msg.len) {
            const written = try posix.write(self.socket, msg[pos..]);
            if (written == 0) {
                return error.Closed;
            }
            pos += written;
        }
    }
};
