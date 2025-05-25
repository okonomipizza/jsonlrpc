const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// Json-RPC version
pub const JsonRPCVersion = enum {
    v2,

    pub fn toString(self: JsonRPCVersion) []const u8 {
        return switch (self) {
            .v2 => "2.0",
        };
    }
};

/// Json-RPC parameters
pub const Params = union(enum) {
    array: json.Array,
    object: json.ObjectMap,

    pub fn toJsonValue(self: Params) json.Value {
        return switch (self) {
            .array => |arr| json.Value{ .array = arr },
            .object => |obj| json.Value{ .object = obj },
        };
    }

    pub fn fromArray(array: json.Array) Params {
        return .{ .array = array };
    }

    pub fn fromObject(object: json.ObjectMap) Params {
        return .{ .object = object };
    }

    pub fn isArray(self: Params) bool {
        return switch (self) {
            .array => true,
            .object => false,
        };
    }

    pub fn isObject(self: Params) bool {
        return switch (self) {
            .array => false,
            .object => true,
        };
    }
};

pub const RequestObject = struct {
    jsonrpc: JsonRPCVersion,
    method: []const u8,
    params: ?Params,
    id: ?json.Value,
    _parsed_data: ?json.Parsed(json.Value) = null,

    pub fn init(method: []const u8, params: ?Params, id: ?json.Value) !RequestObject {
        // Validate id: only String, Number, or Null are allowed
        if (id) |id_value| {
            switch (id_value) {
                .string, .integer, .float, .null => {},
                else => return error.InvalidIdType,
            }
        }
        return .{
            .jsonrpc = .v2,
            .method = method,
            .params = params,
            .id = id,
        };
    }

    pub fn fromSlice(allocator: Allocator, slice: []const u8) !RequestObject {
        const parsed = try json.parseFromSlice(json.Value, allocator, slice, .{});

        if (parsed.value != .object) {
            parsed.deinit();
            return error.InvalidRequest;
        }

        const root_obj = parsed.value.object;

        const method_value = root_obj.get("method") orelse {
            parsed.deinit();
            return error.MissingMethod;
        };

        const method = switch (method_value) {
            .string => |str| str,
            else => {
                parsed.deinit();
                return error.InvalidMethod;
            },
        };

        const params: ?Params = blk: {
            const params_value = root_obj.get("params") orelse break :blk null;
            switch (params_value) {
                .array => |arr| break :blk Params.fromArray(arr),
                .object => |obj| break :blk Params.fromObject(obj),
                else => {
                    parsed.deinit();
                    return error.InvalidParams;
                },
            }
        };

        const id = root_obj.get("id");

        if (id) |id_value| {
            switch (id_value) {
                .string, .integer, .float, .null => {},
                else => return error.InvalidIdType,
            }
        }

        return .{
            .jsonrpc = .v2,
            .method = method,
            .params = params,
            .id = id,
            ._parsed_data = parsed,
        };
    }

    pub fn deinit(self: *RequestObject) void {
        if (self._parsed_data) |parsed| {
            parsed.deinit();
            self._parsed_data = null;
        }
    }

    pub fn serialize(self: RequestObject, allocator: Allocator) ![]u8 {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();

        try obj.put("jsonrpc", json.Value{ .string = self.jsonrpc.toString() });
        try obj.put("method", json.Value{ .string = self.method });

        if (self.params) |params| {
            try obj.put("params", params.toJsonValue());
        }

        if (self.id) |id| {
            try obj.put("id", id);
        }

        return try stringifyToOwnedSlice(allocator, json.Value{ .object = obj });
    }
};

/// A Number that indicates the error type that occurred.
pub const ErrorCode = union(enum) {
    parseError,
    invalidRequest,
    methodNotFound,
    invalidParams,
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
                    // Valid server error range.
                    return .{ .serverError = @intCast(code) };
                } else if (-32768 <= code and code < -32000) {
                    // Reserved range for future use.
                    return error.ReservedErrorCode;
                } else {
                    // Out of reserved range.
                    return error.InvalidErrorCode;
                }
            },
        };
    }
};

pub const ErrorObject = struct {
    code: ErrorCode,
    message: []const u8,
    data: ?json.Value,

    pub fn toJsonValue(self: ErrorObject, allocator: Allocator) !json.Value {
        var obj = json.ObjectMap.init(allocator);
        try obj.put("code", json.Value{ .integer = self.code.value() });
        try obj.put("message", json.Value{ .string = self.message });
        if (self.data) |data| {
            try obj.put("data", data);
        }

        return json.Value{ .object = obj };
    }

    pub fn fromJson(obj: json.Value) !ErrorObject {
        if (obj != .object) return error.InvalidErrorObject;

        const root_object = obj.object;

        const code_value = root_object.get("code") orelse return error.InvalidErrorCode;
        const code: ErrorCode = blk: {
            switch (code_value) {
                .integer => |val| {
                    break :blk try ErrorCode.fromValue(val);
                },
                else => return error.InvalidErrorCode,
            }
        };

        const message_value = root_object.get("message") orelse return error.NoMessage;
        if (message_value != .string) return error.NoMessage;

        const data_value = root_object.get("data");

        return .{
            .code = code,
            .message = message_value.string,
            .data = data_value,
        };
    }
};

pub const ResponseObject = union(enum) {
    Ok: struct {
        jsonrpc: JsonRPCVersion,
        result: json.Value,
        id: json.Value,
        _parsed_data: ?json.Parsed(json.Value) = null,
    },
    Err: struct {
        jsonrpc: JsonRPCVersion,
        @"error": ErrorObject,
        id: json.Value,
        _parsed_data: ?json.Parsed(json.Value) = null,
    },

    /// Create new success response.
    pub fn success(result: json.Value, id: json.Value) ResponseObject {
        return ResponseObject{ .Ok = .{
            .jsonrpc = .v2,
            .result = result,
            .id = id,
        } };
    }

    /// Create new error response.
    pub fn error_response(error_obj: ErrorObject, id: json.Value) ResponseObject {
        return ResponseObject{ .Err = .{
            .jsonrpc = .v2,
            .@"error" = error_obj,
            .id = id,
        } };
    }

    pub fn fromSlice(allocator: Allocator, slice: []const u8) !ResponseObject {
        const parsed = try json.parseFromSlice(json.Value, allocator, slice, .{});

        if (parsed.value != .object) {
            parsed.deinit();
            return error.InvalidRequest;
        }

        const root_obj = parsed.value.object;

        const error_value = root_obj.get("error");
        if (error_value) |@"error"| {
            // Create Error response
            const error_object = try ErrorObject.fromJson(@"error");

            const id = root_obj.get("id") orelse {
                parsed.deinit();
                return error.NoId;
            };
            if (id != .integer and id != .string and id != .null) {
                parsed.deinit();
                return error.InvalidId;
            }

            return ResponseObject{ .Err = .{ .jsonrpc = .v2, .@"error" = error_object, .id = id, ._parsed_data = parsed } };
        } else {
            // Parse Ok response
            const result = root_obj.get("result") orelse {
                parsed.deinit();
                return error.NoResult;
            };
            const id = root_obj.get("id") orelse {
                parsed.deinit();
                return error.NoId;
            };
            if (id != .integer and id != .string and id != .null) {
                parsed.deinit();
                return error.InvalidId;
            }

            return ResponseObject{ .Ok = .{ .jsonrpc = .v2, .result = result, .id = id, ._parsed_data = parsed } };
        }
    }

    pub fn serialize(self: ResponseObject, allocator: Allocator) ![]const u8 {
        var obj = json.ObjectMap.init(allocator);
        defer obj.deinit();
        switch (self) {
            .Ok => |ok| {
                try obj.put("jsonrpc", json.Value{ .string = ok.jsonrpc.toString() });
                try obj.put("result", ok.result);
                try obj.put("id", ok.id);

                return try stringifyToOwnedSlice(allocator, json.Value{ .object = obj });
            },
            .Err => |err| {
                try obj.put("jsonrpc", json.Value{ .string = err.jsonrpc.toString() });
                var err_obj_json = try err.@"error".toJsonValue(allocator);
                defer err_obj_json.object.deinit();

                try obj.put("error", err_obj_json);
                try obj.put("id", err.id);

                return try stringifyToOwnedSlice(allocator, json.Value{ .object = obj });
            },
        }
    }

    pub fn isSuccess(self: ResponseObject) bool {
        switch (self) {
            .Ok => return true,
            .Err => return false,
        }
    }

    pub fn deinit(self: *ResponseObject) void {
        switch (self.*) {
            .Ok => |*ok| {
                if (ok._parsed_data) |parsed| {
                    parsed.deinit();
                    ok._parsed_data = null;
                }
            },
            .Err => |*err| {
                if (err._parsed_data) |parsed| {
                    parsed.deinit();
                    err._parsed_data = null;
                }
            },
        }
    }
};

fn stringifyToOwnedSlice(allocator: Allocator, value: json.Value) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();

    try json.stringify(value, .{}, buffer.writer());
    return buffer.toOwnedSlice();
}

test "success response serialization" {
    const allocator = std.testing.allocator;

    var response = ResponseObject.success(json.Value{ .integer = 10 }, json.Value{ .integer = 1 });
    const serialized = try response.serialize(allocator);
    defer allocator.free(serialized);
    std.debug.print("Serialized Responses JSON: {s}\n", .{serialized});

    const expected_contains = [_][]const u8{
        "\"jsonrpc\":\"2.0\"",
        "\"result\":10",
        "\"id\":1",
    };

    for (expected_contains) |expected_part| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, expected_part) != null);
    }
}

test "error response serialization" {
    const allocator = std.testing.allocator;
    const error_obj = ErrorObject{
        .code = try ErrorCode.fromValue(-32700),
        .message = "Parse error",
        .data = null,
    };

    var response = ResponseObject.error_response(error_obj, json.Value{ .integer = 1 });
    const serialized = try response.serialize(allocator);
    defer allocator.free(serialized);
    std.debug.print("Serialized Responses JSON: {s}\n", .{serialized});

    const expected_contains = [_][]const u8{
        "\"jsonrpc\":\"2.0\"",
        "\"error\":{\"code\":-32700,\"message\":\"Parse error\"}",
        "\"id\":1",
    };

    for (expected_contains) |expected_part| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, expected_part) != null);
    }
}

test "parse success response object from slice" {
    const allocator = std.testing.allocator;
    const json_string = "{\"jsonrpc\":\"2.0\",\"result\":10,\"id\":1}";
    var response = try ResponseObject.fromSlice(allocator, json_string);
    defer response.deinit();

    try std.testing.expect(response.isSuccess());

    try std.testing.expectEqual(JsonRPCVersion.v2, response.Ok.jsonrpc);

    try std.testing.expectEqual(10, response.Ok.result.integer);

    try std.testing.expectEqual(1, response.Ok.id.integer);
}

test "parse error response object from slice" {
    const allocator = std.testing.allocator;
    const json_string = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":1}";
    var response = try ResponseObject.fromSlice(allocator, json_string);
    defer response.deinit();

    try std.testing.expect(!response.isSuccess());

    try std.testing.expectEqual(JsonRPCVersion.v2, response.Err.jsonrpc);

    try std.testing.expectEqual(-32700, response.Err.@"error".code.value());

    try std.testing.expectEqualStrings("Parse error", response.Err.@"error".message);

    try std.testing.expectEqual(1, response.Err.id.integer);
}

test "request serialization with array params" {
    const allocator = std.testing.allocator;

    var params_array = json.Array.init(allocator);
    defer params_array.deinit();
    try params_array.append(json.Value{ .string = "user1" });
    try params_array.append(json.Value{ .string = "user2" });

    const params = Params.fromArray(params_array);
    const id = json.Value{ .integer = 1 };
    const req = try RequestObject.init("get", params, id);

    const serialized = try req.serialize(allocator);
    defer allocator.free(serialized);

    std.debug.print("Serialized JSON: {s}\n", .{serialized});

    const expected_contains = [_][]const u8{
        "\"jsonrpc\":\"2.0\"",
        "\"method\":\"get\"",
        "\"params\":[\"user1\",\"user2\"]",
        "\"id\":1",
    };

    for (expected_contains) |expected_part| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, expected_part) != null);
    }
}

test "request serialization with object params" {
    const allocator = std.testing.allocator;

    var params_obj = json.ObjectMap.init(allocator);
    defer params_obj.deinit();
    try params_obj.put("subtrahend", json.Value{ .integer = 2 });
    try params_obj.put("minuend", json.Value{ .integer = 42 });

    const params = Params.fromObject(params_obj);
    const id = json.Value{ .integer = 1 };
    const req = try RequestObject.init("subtract", params, id);

    const serialized = try req.serialize(allocator);
    defer allocator.free(serialized);

    std.debug.print("Serialized JSON: {s}\n", .{serialized});

    const expected_contains = [_][]const u8{
        "\"jsonrpc\":\"2.0\"",
        "\"method\":\"subtract\"",
        "\"params\":{\"subtrahend\":2,\"minuend\":42}",
        "\"id\":1",
    };

    for (expected_contains) |expected_part| {
        try std.testing.expect(std.mem.indexOf(u8, serialized, expected_part) != null);
    }
}

test "ID validation" {
    const allocator = std.testing.allocator;

    // Tests for valid ID types
    // String ID
    const req1 = try RequestObject.init("test", null, json.Value{ .string = "abc-123" });
    try std.testing.expect(req1.id != null);

    // Integer ID
    const req2 = try RequestObject.init("test", null, json.Value{ .integer = 42 });
    try std.testing.expect(req2.id != null);

    // Float ID
    const req3 = try RequestObject.init("test", null, json.Value{ .float = 3.14 });
    try std.testing.expect(req3.id != null);

    // Null ID
    const req4 = try RequestObject.init("test", null, json.Value{ .null = {} });
    try std.testing.expect(req4.id != null);

    // No ID (null)
    const req5 = try RequestObject.init("test", null, null);
    try std.testing.expect(req5.id == null);

    // Tests for invalid ID types
    // Boolean (should fail)
    const result_bool = RequestObject.init("test", null, json.Value{ .bool = true });
    try std.testing.expectError(error.InvalidIdType, result_bool);

    // Array (should fail)
    var array = json.Array.init(allocator);
    defer array.deinit();
    try array.append(json.Value{ .integer = 1 });
    const result_array = RequestObject.init("test", null, json.Value{ .array = array });
    try std.testing.expectError(error.InvalidIdType, result_array);

    // Object (should fail)
    var object = json.ObjectMap.init(allocator);
    defer object.deinit();
    try object.put("key", json.Value{ .string = "value" });
    const result_object = RequestObject.init("test", null, json.Value{ .object = object });
    try std.testing.expectError(error.InvalidIdType, result_object);
}

test "parse request from slice with array params" {
    const json_string = "{\"jsonrpc\":\"2.0\",\"method\":\"get\",\"params\":[\"user1\",\"user2\"],\"id\":1}";
    var parsed = try RequestObject.fromSlice(std.testing.allocator, json_string);
    defer parsed.deinit();

    try std.testing.expectEqual(JsonRPCVersion.v2, parsed.jsonrpc);

    try std.testing.expectEqualStrings("get", parsed.method);

    if (parsed.params) |params| {
        if (params.isArray()) {
            try std.testing.expectEqualStrings("user1", params.array.items[0].string);
            try std.testing.expectEqualStrings("user2", params.array.items[1].string);
        } else {
            return error.InvalidParams;
        }
    } else return error.NoParams;

    if (parsed.id) |id| {
        try std.testing.expectEqual(1, id.integer);
    } else return error.InvalidId;
}

test "parse request from slice with object params" {
    const json_string = "{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":{\"subtrahend\":2,\"minuend\":42},\"id\":1}";
    var parsed = try RequestObject.fromSlice(std.testing.allocator, json_string);
    defer parsed.deinit();

    try std.testing.expectEqual(JsonRPCVersion.v2, parsed.jsonrpc);

    try std.testing.expectEqualStrings("subtract", parsed.method);

    if (parsed.params) |params| {
        if (params.isObject()) {
            try std.testing.expectEqual(2, params.object.get("subtrahend").?.integer);
            try std.testing.expectEqual(42, params.object.get("minuend").?.integer);
        } else {
            return error.InvalidParams;
        }
    } else return error.NoParams;

    if (parsed.id) |id| {
        try std.testing.expectEqual(1, id.integer);
    } else return error.InvalidId;
}
