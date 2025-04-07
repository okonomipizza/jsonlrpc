// JSON-RPC 2.0 Specification
// https://www.jsonrpc.org/specification

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Error = error{
    InvalidJsonLine,
    InvalidRequest,
    InvalidId,
    InvalidParams,
};

pub const JsonRpcVersion = enum {
    v2,

    pub fn toString(self: JsonRpcVersion) []const u8 {
        return switch (self) {
            .v2 => "2.0",
        };
    }
};

pub const RequestObject = struct {
    /// JSON-RPC version. MUST be exactly "2.0".
    jsonrpc: JsonRpcVersion,

    /// Method name to be invoked.
    method: []const u8,

    /// Request parameters.
    params: ?json.Value,

    /// Request ID.
    ///
    /// If null, it is notification.
    id: ?json.Value,

    pub fn init(version: JsonRpcVersion, method: []const u8, params: ?json.Value, id: ?json.Value) !RequestObject {
        const obj = RequestObject{
            .jsonrpc = version,
            .id = id,
            .method = method,
            .params = params,
        };
        try obj.validate();

        return obj;
    }

    /// Deserializes a JSONL format byte slice into a RequestObject.
    /// The input may contain a trailing newline which will be handled correctrly.
    pub fn fromSlice(allocator: Allocator, data: []const u8) !RequestObject {
        var parsed = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed.deinit();

        const jsonrpc_value = parsed.value.object.get("jsonrpc") orelse return Error.InvalidRequest;
        if (jsonrpc_value != .string) return Error.InvalidId;

        var version: JsonRpcVersion = undefined;
        if (std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
            version = .v2;
        } else {
            return Error.InvalidRequest;
        }

        const method = parsed.value.object.get("method") orelse return Error.InvalidRequest;
        if (method != .string or method.string.len == 0) {
            return Error.InvalidRequest;
        }

        const id = parsed.value.object.get("id");
        const params = parsed.value.object.get("params");

        const obj = RequestObject{
            .jsonrpc = version,
            .id = id,
            .method = method.string,
            .params = params,
        };
        try obj.validate();

        return obj;
    }

    fn validate(self: RequestObject) !void {
        if (self.id != null) {
            switch (self.id.?) {
                .integer, .string => {}, // OK
                else => return Error.InvalidId,
            }
        }
        if (self.params != null) {
            switch (self.params.?) {
                .object, .array => {}, // OK
                else => return Error.InvalidParams,
            }
        }
    }

    pub fn serialize(self: RequestObject, allocator: Allocator) ![]u8 {
        var value = json.Value{
            .object = json.ObjectMap.init(allocator),
        };

        try value.object.put("jsonrpc", json.Value{ .string = self.jsonrpc.toString() });
        if (self.id != null) {
            try value.object.put("id", self.id.?);
        }

        try value.object.put("method", json.Value{ .string = self.method });
        if (self.params != null) {
            try value.object.put("params", self.params.?);
        }

        var buffer = std.ArrayList(u8).init(allocator);
        try json.stringify(value, .{}, buffer.writer());
        try buffer.append('\n'); // Add newline for JSONL format
        return buffer.toOwnedSlice();
    }
};

test "RequestObject serialization/deserialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // {"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
    const method = "subtract";
    var params = json.Value{ .array = json.Array.init(allocator) };
    try params.array.append(json.Value{ .integer = 42 });
    try params.array.append(json.Value{ .integer = 23 });
    const id = json.Value{ .integer = 1 };

    var original_request = try RequestObject.init(JsonRpcVersion.v2, method, params, id);

    const serialized = try original_request.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized_request = try RequestObject.fromSlice(allocator, serialized);

    try testing.expectEqual(original_request.jsonrpc, deserialized_request.jsonrpc);
    try testing.expectEqualStrings(original_request.method, deserialized_request.method);

    try testing.expect(original_request.id != null and deserialized_request.id != null);
    try testing.expectEqual(original_request.id.?.integer, deserialized_request.id.?.integer);

    try testing.expectEqual(original_request.params.?.array.items.len, deserialized_request.params.?.array.items.len);
    try testing.expectEqual(original_request.params.?.array.items[0].integer, deserialized_request.params.?.array.items[0].integer);
    try testing.expectEqual(original_request.params.?.array.items[1].integer, deserialized_request.params.?.array.items[1].integer);
}

test "Invalid id type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const method = "subtract";
    var params = json.Value{ .array = json.Array.init(allocator) };
    try params.array.append(json.Value{ .integer = 42 });
    try params.array.append(json.Value{ .integer = 23 });

    try testing.expectError(Error.InvalidId, RequestObject.init(JsonRpcVersion.v2, method, params, params));
}

test "Invalid params type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const method = "test";
    const invalid_params = json.Value{ .string = "this is not allowed" };
    const id = json.Value{ .integer = 1 };

    try testing.expectError(Error.InvalidParams, RequestObject.init(JsonRpcVersion.v2, method, invalid_params, id));
}
