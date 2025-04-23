// JSON-RPC 2.0 Specification
// https://www.jsonrpc.org/specification

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const testing = std.testing;

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
    pub fn fromValue(code: i32) !ErrorCode {
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
                    return error.ReservedErrorCode;
                } else {
                    // Out of reserved range
                    return error.InvalidErrorCode;
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
pub const ResponseObject = struct {
    json_value: json.Value,
    arena: *std.heap.ArenaAllocator,
    // Kind of response success or error
    tag: enum { state_success, state_error },

    pub fn newSuccess(allocator: Allocator, version: JsonRpcVersion, result: json.Value, id: json.Value) !ResponseObject {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var object_map = json.ObjectMap.init(arena.allocator());
        errdefer object_map.deinit();

        var root = json.Value{ .object = object_map };
        try root.object.put("jsonrpc", json.Value{ .string = version.toString() });
        try root.object.put("result", result);
        try root.object.put("id", id);

        return ResponseObject{
            .json_value = root,
            .arena = arena,
            .tag = .state_success,
        };
    }

    pub fn newError(
        allocator: Allocator,
        version: JsonRpcVersion,
        code: ErrorCode,
        message: []const u8,
        data: ?json.Value,
        id: ?json.Value,
    ) !ResponseObject {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var object_map = json.ObjectMap.init(arena.allocator());
        errdefer object_map.deinit();

        var root = json.Value{ .object = object_map };

        try root.object.put("jsonrpc", json.Value{ .string = version.toString() });

        var error_obj = json.Value{ .object = json.ObjectMap.init(arena.allocator()) };
        try error_obj.object.put("code", json.Value{ .integer = code.value() });
        try error_obj.object.put("message", json.Value{ .string = message });

        if (data) |d| {
            try error_obj.object.put("data", d);
        }

        try root.object.put("error", error_obj);

        if (id) |i| {
            try root.object.put("id", i);
        }

        return ResponseObject{
            .json_value = root,
            .arena = arena,
            .tag = .state_error,
        };
    }

    /// Deserializes a JSONL format byte slice into a ResponseObject.
    pub fn fromSlice(allocator: Allocator, data: []const u8) !ResponseObject {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        var parsed_json = try json.parseFromSlice(json.Value, arena.allocator(), data, .{});

        // Get json rpc version.
        const jsonrpc_value = parsed_json.value.object.get("jsonrpc") orelse {
            parsed_json.deinit();
            return error.WithoutProtocolVersion;
        };
        if (jsonrpc_value != .string) {
            parsed_json.deinit();
            return error.InvalidProtocolVersion;
        }

        var version: JsonRpcVersion = undefined;
        if (std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
            version = .v2;
        } else {
            parsed_json.deinit();
            return error.InvalidProtocolVersion;
        }

        // Handle error response.
        const error_value = parsed_json.value.object.get("error");
        if (error_value) |err_value| {
            if (err_value != .object) {
                parsed_json.deinit();
                return error.InvalidErrorObject;
            }

            if (err_value.object.get("code") == null) {
                parsed_json.deinit();
                return error.WithoutErrorCode;
            }

            if (err_value.object.get("message") == null) {
                parsed_json.deinit();
                return error.WithoutErrorMessage;
            }

            return ResponseObject{
                .json_value = parsed_json.value,
                .arena = arena,
                .tag = .state_error,
            };
        } else {
            // Handle success response
            if (parsed_json.value.object.get("result") == null) {
                parsed_json.deinit();
                return error.NoResult;
            }

            if (parsed_json.value.object.get("id") == null) {
                parsed_json.deinit();
                return error.NoId;
            }

            return ResponseObject{
                .json_value = parsed_json.value,
                .arena = arena,
                .tag = .state_success,
            };
        }
    }

    pub fn deinit(self: *ResponseObject) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }

    pub fn getJsonRpcVersion(self: ResponseObject) !JsonRpcVersion {
        const jsonrpc_value = self.json_value.object.get("jsonrpc") orelse
            return error.WithoutProtocolVersion;

        if (jsonrpc_value != .string)
            return error.InvalidProtocolVersion;

        if (std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
            return .v2;
        } else {
            return error.InvalidProtocolVersion;
        }
    }

    pub fn isSuccess(self: ResponseObject) bool {
        return self.tag == .state_success;
    }

    pub fn isError(self: ResponseObject) bool {
        return self.tag == .state_error;
    }

    pub fn getResult(self: ResponseObject) ?json.Value {
        if (self.isError()) return null;
        return self.json_value.object.get("result");
    }

    pub fn getId(self: ResponseObject) ?json.Value {
        return self.json_value.object.get("id");
    }

    pub fn getErrorCode(self: ResponseObject) !ErrorCode {
        if (!isError()) return error.NotErrorResponse;

        const error_obj = self.json_value.object.get("error") orelse
            return error.InvalidErrorObject;

        if (error_obj != .object)
            return error.InvalidErrorObject;

        const code_value = error_obj.object.get("code") orelse
            return error.WithoutErrorCode;

        if (code_value != .integer)
            return error.InvalidErrorCode;

        return ErrorCode.fromValue(code_value.integer);
    }

    pub fn getErrorMessage(self: ResponseObject) ![]const u8 {
        if (!self.isError()) return error.NotErrorResponse;

        const error_obj = self.json_value.object.get("error") orelse
            return error.InvalidErrorObject;

        if (error_obj != .object)
            return error.InvalidErrorObject;

        const message_value = error_obj.object.get("message") orelse
            return error.WithoutErrorMessage;

        if (message_value != .string)
            return error.InvalidErrorMessage;

        return message_value.string;
    }

    pub fn getErrorData(self: ResponseObject) ?json.Value {
        if (!isError()) return null;

        const error_obj = self.json_value.object.get("error") orelse return null;
        if (error_obj != .object) return null;

        return error_obj.object.get("data");
    }

    /// Serialize response object.
    pub fn serialize(self: ResponseObject, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        try json.stringify(self.json_value, .{}, buffer.writer());
        try buffer.append('\n'); // Add newline for JSONL format

        return buffer.toOwnedSlice();
    }
};

pub const RequestObject = struct {
    /// original whole json value
    json_value: json.Value,
    allocator: Allocator,

    pub fn init(allocator: Allocator, version: JsonRpcVersion, method: []const u8, params: ?json.Value, id: ?json.Value) !RequestObject {
        var object_map = json.ObjectMap.init(allocator);
        errdefer object_map.deinit();

        var root = json.Value{ .object = object_map };

        // set each field
        try root.object.put("jsonrpc", json.Value{ .string = version.toString() });
        try root.object.put("method", json.Value{ .string = method });

        if (params) |p| {
            try root.object.put("params", p);
        }

        if (id) |i| {
            try root.object.put("id", i);
        }

        const obj = RequestObject{
            .json_value = root,
            .allocator = allocator,
        };

        try obj.validate();

        return obj;
    }

    pub fn fromSlice(allocator: Allocator, data: []const u8) !RequestObject {
        var parsed = try json.parseFromSlice(json.Value, allocator, data, .{});

        var obj = RequestObject{
            .json_value = parsed.value,
            .allocator = allocator,
        };

        // オブジェクトの検証
        if (obj.validate()) |_| {
            return obj;
        } else |err| {
            // 検証失敗時にはメモリを解放して終了
            parsed.deinit();
            return err;
        }
    }

    pub fn deinit(self: *RequestObject) void {
        self.json_value.object.deinit();
    }

    pub fn getJsonRpcVersion(self: RequestObject) !JsonRpcVersion {
        const jsonrpc_value = self.json_value.object.get("jsonrpc") orelse return error.WithoutJsonRpcVersion;
        if (jsonrpc_value != .string) return error.WithoutJsonRpcVersion;

        if (std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
            return .v2;
        } else {
            return error.InvalidJsonRpcVersion;
        }
    }

    pub fn getMethod(self: RequestObject) !?[]const u8 {
        const method = self.json_value.object.get("method") orelse return null;
        if (method != .string or method.string.len == 0) {
            return error.InvalidRequestMethod;
        }
        return method.string;
    }

    pub fn getParams(self: RequestObject) ?json.Value {
        return self.json_value.object.get("params");
    }

    pub fn getId(self: RequestObject) ?json.Value {
        return self.json_value.object.get("id");
    }

    pub fn isNotification(self: RequestObject) bool {
        return self.getId() == null;
    }

    fn validate(self: RequestObject) !void {
        _ = try self.getJsonRpcVersion();

        _ = try self.getMethod();

        if (self.getId()) |id| {
            switch (id) {
                .integer, .string, .null => {}, // OK
                else => return error.InvalidId,
            }
        }

        if (self.getParams()) |params| {
            switch (params) {
                .object, .array => {}, // OK
                else => return error.InvalidParams,
            }
        }
    }

    pub fn serialize(self: RequestObject, allocator: Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        try json.stringify(self.json_value, .{}, buffer.writer());
        try buffer.append('\n'); // Add newline for JSONL format

        return buffer.toOwnedSlice();
    }
};
