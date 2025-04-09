// JSON-RPC 2.0 Specification
// https://www.jsonrpc.org/specification

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Errors
pub const Error = error{
    // Errors related to request
    InvalidJsonLine, InvalidRequest, InvalidId, InvalidParams,

    // Errors related to response
    Notification, NoIdProvided, NoResultProvided, MessageMustBeString, MessageParseError, ProvidedErrorCodeNotInteger, NoErrorCode, ProvidedErrorNotObject, InvalidErrorObject, InvalidErrorCode, ReservedErrorCode, NoProtocolVersionProvided, UnsupportedRPCVersion };

/// JSON-RPC version
pub const JsonRpcVersion = enum {
    v2,

    /// Returns JSON-RPC version in string.
    pub fn toString(self: JsonRpcVersion) []const u8 {
        return switch (self) {
            .v2 => "2.0",
        };
    }
};

/// Error code that indicates the error type
const ErrorCode = union(enum) {
    /// Parse error.
    parseError,
    /// Invalid request.
    invalidRequest,
    /// Method not found.
    methodNotFound,
    /// Invalid parameters.
    invalidParams,
    /// Internal error.
    internalError,
    /// Reserved for implementation-defined server-errors.
    serverError: i32,

    /// Returns the value of the error code.
    pub fn value(self: ErrorCode) i32 {
        return switch (self) {
            .parseError => -32700,
            .invalidRequest => -32600,
            .methodNotFound => -32601,
            .invalidParams => -32602,
            .internalError => -32603,
            .serverError => |code| code,
        };
    }

    /// Returns the ErrorCode from integer.
    pub fn fromValue(code: i64) !ErrorCode {
        return switch (code) {
            -32700 => .parseError,
            -32600 => .invalidRequest,
            -32601 => .methodNotFound,
            -32602 => .invalidParams,
            -32603 => .internalError,
            else => {
                if (-32099 <= code and code <= -32000) {
                    // Valid server error range
                    return .{ .serverError = @intCast(code) };
                } else if (-32768 <= code and code < -32000) {
                    // Reserved range for future use
                    return Error.ReservedErrorCode;
                } else {
                    // Out of reserved range
                    return Error.InvalidErrorCode;
                }
            },
        };
    }
};

/// ErrorObject
pub const ErrorObject = struct {
    /// Error code.
    code: ErrorCode,
    /// Error message.
    message: []const u8,
    /// Structured (array or object) value that contains additional information about the error.
    data: ?json.Value,

    /// Create a new ErrorObject.
    pub fn new(code: ErrorCode, message: []const u8, data: ?json.Value) ErrorObject {
        return ErrorObject{ .code = code, .message = message, .data = data };
    }
};

/// Response object
pub const ResponseObject = union(enum) {
    success: struct {
        jsonrpc: JsonRpcVersion,
        result: json.Value,
        id: json.Value,
    },
    err: struct {
        jsonrpc: JsonRpcVersion,
        err: ErrorObject,
        /// The id may be null in cases such as Parse error or Invalid request.
        id: ?json.Value,
    },

    pub fn newSuccess(version: JsonRpcVersion, result: json.Value, id: json.Value) ResponseObject {
        return .{
            .success = .{
                .jsonrpc = version,
                .result = result,
                .id = id,
            },
        };
    }

    pub fn newError(
        version: JsonRpcVersion,
        code: ErrorCode,
        message: []const u8,
        data: ?json.Value,
        id: ?json.Value,
    ) ResponseObject {
        const errorObject = ErrorObject.new(code, message, data);
        return .{ .err = .{
            .jsonrpc = version,
            .err = errorObject,
            .id = id,
        } };
    }

    /// Deserializes a JSONL format byte slice into a ResponseObject.
    pub fn fromSlice(allocator: Allocator, data: []const u8) !ResponseObject {
        var parsed_json = try json.parseFromSlice(json.Value, allocator, data, .{});
        defer parsed_json.deinit();

        // Get json rpc version.
        const jsonrpc_value = parsed_json.value.object.get("jsonrpc") orelse return Error.NoProtocolVersionProvided;
        if (jsonrpc_value != .string) return Error.NoProtocolVersionProvided;
        var version: JsonRpcVersion = undefined;
        if (std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
            version = .v2;
        } else {
            return Error.UnsupportedRPCVersion;
        }

        // Handle error response.
        const error_value = parsed_json.value.object.get("error");
        if (error_value) |err_value| {
            if (err_value != .object) return Error.ProvidedErrorNotObject;

            // Parse error code
            const code_value = err_value.object.get("code") orelse return Error.NoErrorCode;
            if (code_value != .integer) return Error.ProvidedErrorCodeNotInteger;
            const code = try ErrorCode.fromValue(code_value.integer);

            // Parse error message
            const message_value = err_value.object.get("message") orelse return Error.MessageParseError;
            if (message_value != .string) return Error.MessageMustBeString;
            const message = message_value.string;

            // Parse optional data
            const data_value = err_value.object.get("data");

            // Parse optional id
            const id = parsed_json.value.object.get("id");

            return ResponseObject.newError(version, code, message, data_value, id);
        } else {
            // Handle success response
            const result = parsed_json.value.object.get("result") orelse return Error.NoResultProvided;
            const id = parsed_json.value.object.get("id") orelse return Error.NoIdProvided;

            return ResponseObject.newSuccess(version, result, id);
        }
    }

    /// Serialize response object.
    pub fn serialize(self: ResponseObject, allocator: Allocator) ![]u8 {
        var value = json.Value{ .object = json.ObjectMap.init(allocator) };

        switch (self) {
            .success => {
                try value.object.put("jsonrpc", json.Value{ .string = self.success.jsonrpc.toString() });
                try value.object.put("result", self.success.result);
                try value.object.put("id", self.success.id);
            },
            .err => {
                try value.object.put("jsonrpc", json.Value{ .string = self.err.jsonrpc.toString() });

                var error_obj = json.Value{ .object = json.ObjectMap.init(allocator) };
                try error_obj.object.put("code", json.Value{ .integer = self.err.err.code.value() });
                try error_obj.object.put("message", json.Value{ .string = self.err.err.message });

                if (self.err.err.data) |data| {
                    try error_obj.object.put("data", data);
                }

                try value.object.put("error", error_obj);

                if (self.err.id) |id| {
                    try value.object.put("id", id);
                } else {
                    return error.Notification;
                }
            },
        }

        var buffer = std.ArrayList(u8).init(allocator);
        try json.stringify(value, .{}, buffer.writer());
        try buffer.append('\n'); // Add newline for JSONL format
        return buffer.toOwnedSlice();
    }
};

test "ResponseObject success serialization/deserialization with integer result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = json.Value{ .integer = 19 }; // 42 - 23 = 19
    const id = json.Value{ .integer = 1 };

    const original_response = ResponseObject.newSuccess(JsonRpcVersion.v2, result, id);

    const serialized = try original_response.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized_response = try ResponseObject.fromSlice(allocator, serialized);

    // Check response type
    try testing.expect(deserialized_response == .success);
    // Check version
    try testing.expectEqual(original_response.success.jsonrpc, deserialized_response.success.jsonrpc);

    // Check result type and value
    try testing.expect(deserialized_response.success.result == .integer);
    try testing.expectEqual(original_response.success.result.integer, deserialized_response.success.result.integer);

    // Check id type and value
    try testing.expect(deserialized_response.success.id == .integer);
    try testing.expectEqual(original_response.success.id.integer, deserialized_response.success.id.integer);
}

test "ResponseObject error serialization/deserialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const error_code = ErrorCode.invalidRequest;
    const error_message = "Invalid Request";
    const id = json.Value{ .integer = 1 };
    const data = json.Value{ .string = "Additional error information" };

    const original_response = ResponseObject.newError(JsonRpcVersion.v2, error_code, error_message, data, id);

    const serialized = try original_response.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized_response = try ResponseObject.fromSlice(allocator, serialized);

    // Check type of response
    try testing.expect(deserialized_response == .err);
    // Check the version
    try testing.expectEqual(original_response.err.jsonrpc, deserialized_response.err.jsonrpc);
    // Check error code.
    try testing.expectEqual(original_response.err.err.code.value(), deserialized_response.err.err.code.value());
    // Check error message.
    try testing.expectEqualStrings(original_response.err.err.message, deserialized_response.err.err.message);
    // Check request id
    try testing.expect(deserialized_response.err.id != null);

    // Check id value based on its actual type
    switch (deserialized_response.err.id.?) {
        .integer => |int_val| try testing.expectEqual(original_response.err.id.?.integer, int_val),
        .string => |str_val| try testing.expectEqualStrings(original_response.err.id.?.string, str_val),
        else => try testing.expect(false), // Unexpected type
    }

    // Check data value
    try testing.expect(deserialized_response.err.err.data != null);
    try testing.expectEqualStrings(original_response.err.err.data.?.string, deserialized_response.err.err.data.?.string);
}

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
