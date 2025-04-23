const JsonStream = @import("io.zig").JsonStream;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;
const Reader = @import("io.zig").Reader;
const Writer = @import("io.zig").Writer;
const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// `RpcClient` provides a client implementation for JSON-RPC protocol communication over a socket.
/// It handles serialization and deserialization of requests and responses, and supports
/// both individual and batch requests.
pub const RpcClient = struct {
    /// Socket file descriptor used for communication
    socket: posix.socket_t,
    /// Reader instance for handling incoming data from the socket
    reader: Reader,

    allocator: Allocator,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !RpcClient {
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

    /// Performs an RPC call (request) and waits for a response
    ///
    /// request: A single RequestObject or a slice of RequestObjects
    pub fn call(self: *RpcClient, request: anytype) ![][]u8 {
        const T = @TypeOf(request);
        const allocator = self.allocator;

        if (T == RequestObject) {
            // Handle single structure
            const serialized_request = try request.serialize(allocator);
            defer allocator.free(serialized_request);

            try self.sendRequest(serialized_request);

            return try self.readResponse();
        } else if (@typeInfo(T) == .pointer) {
            // For slice or array types
            const child = @typeInfo(T).pointer.child;
            if (child == RequestObject) {
                var serialized_requests = std.ArrayList([]u8).init(allocator);
                errdefer serialized_requests.deinit();

                for (request) |req| {
                    const serialized = try req.serialize(allocator);
                    try serialized_requests.append(serialized);
                }

                const data = try serialized_requests.toOwnedSlice();
                defer allocator.free(data);

                try self.sendRequests(data);

                return try self.readResponse();
            } // Handle []*RequestObject
            else if (@typeInfo(child) == .pointer and @typeInfo(child).pointer.child == RequestObject) {
                var serialized_requests = std.ArrayList([]u8).init(allocator);
                errdefer serialized_requests.deinit();

                for (request) |req_ptr| {
                    const serialized = try req_ptr.serialize(allocator);
                    try serialized_requests.append(serialized);
                }

                const data = try serialized_requests.toOwnedSlice();
                defer {
                    for (data) |d| {
                        allocator.free(d);
                    }
                    allocator.free(data);
                }

                try self.sendRequests(data);

                return try self.readResponse();
            } else {
                @compileError("Expected RequestObject or []RequestObject, got " ++ @typeName(T));
            }
        } else {
            @compileError("Expected RequestObject or []RequestObject, got " ++ @typeName(T));
        }
    }

    /// Performs an RPC notification (no response expected)
    /// request: A single RequestObject or a slice of RequestObjects
    pub fn cast(self: *RpcClient, request: anytype) !void {
        const T = @TypeOf(request);
        const allocator = self.allocator;

        if (T == RequestObject) {
            // Handle single structure
            const serialized_request = try request.serialize(allocator);
            defer allocator.free(serialized_request);

            try self.sendRequest(serialized_request);

            return;
        } else if (@typeInfo(T) == .pointer) {
            // For slice or array types
            const child = @typeInfo(T).pointer.child;
            if (child == RequestObject) {
                var serialized_requests = std.ArrayList([]u8).init(allocator);
                errdefer serialized_requests.deinit();

                for (request) |req| {
                    const serialized = try req.serialize(allocator);
                    try serialized_requests.append(serialized);
                }

                const data = try serialized_requests.toOwnedSlice();
                defer allocator.free(data);

                try self.sendRequests(data);

                return;
            } // Handle []*RequestObject
            else if (@typeInfo(child) == .pointer and @typeInfo(child).pointer.child == RequestObject) {
                var serialized_requests = std.ArrayList([]u8).init(allocator);
                errdefer serialized_requests.deinit();

                for (request) |req_ptr| {
                    const serialized = try req_ptr.serialize(allocator);
                    try serialized_requests.append(serialized);
                }

                const data = try serialized_requests.toOwnedSlice();
                defer {
                    for (data) |d| {
                        allocator.free(d);
                    }
                    allocator.free(data);
                }

                try self.sendRequests(data);

                return;
            } else {
                @compileError("Expected RequestObject or []RequestObject, got " ++ @typeName(T));
            }
        } else {
            @compileError("Expected RequestObject or []RequestObject, got " ++ @typeName(T));
        }
    }

    /// Reads response messages from the socket
    fn readResponse(self: *RpcClient) ![][]u8 {
        return self.reader.readMessage(self.allocator, self.socket) catch |err| {
            std.debug.print("Error: {}", .{err});
            return err;
        };
    }

    /// Sends a single serialized request message over the socket
    fn sendRequest(self: *RpcClient, message: []const u8) !void {
        const socket = self.socket;
        return try Writer.writeMessage(socket, message);
    }

    /// Sends multiple serialized request messages over the socket using vectored I/O
    fn sendRequests(self: *RpcClient, messages: []const []const u8) !void {
        return try Writer.writeMessages(self.allocator, self.socket, messages);
    }
};
