const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

/// Version of JSON-RPC protocol
/// Must be exactly "2.0"
pub const JsonRpcVersion = enum {
    v2,

    pub fn toString(self: JsonRpcVersion) []const u8 {
        return switch (self) {
            .v2 => "2.0",
        };
    }
};

pub const Params = union(enum) {
    array: json.Array,
    object: json.ObjectMap,

    pub fn toJson(self: Params) json.Value {
        return switch (self) {
            .array => |arr| json.Value{ .array = arr },
            .object => |obj| json.Value{ .object = obj },
        };
    }

    pub fn fromArray(array: json.Array) Params {
        return Params{ .array = array };
    }

    pub fn fromObject(object: json.ObjectMap) Params {
        return Params{ .object = object };
    }
};

pub const RequestId = union(enum) {
    number: i64,
    string: []const u8,

    pub fn toJson(self: RequestId) json.Value {
        return switch (self) {
            .number => |num| json.Value{ .integer = num },
            .string => |str| json.Value{ .string = str },
        };
    }
};

pub const RequestObject = struct {
    /// Protocol version
    jsonrpc: JsonRpcVersion,
    /// Name of the method to be invoked
    method: []const u8,
    /// Params holds the parameter value to be used during the invocation of the method
    params: ?Params,
    /// Request ID
    /// If null, it will be consumed as notification
    id: ?RequestId,
    _parsed_data: json.Parsed(json.Value),

    pub fn init(jsonrpc: JsonRpcVersion, method: []const u8, params: ?Params, id: ?RequestId) RequestObject {
        return .{
            .jsonrpc = jsonrpc,
            .method = method,
            .params = params,
            .id = id,
            ._parsed_data = undefined,
        };
    }

    pub fn deinit(self: *RequestObject) void {
        self._parsed_data.deinit();
    }

    pub fn fromSlice(allocator: Allocator, jsonString: []const u8) !RequestObject {
        const parsedJson = try json.parseFromSlice(json.Value, allocator, jsonString, .{});
        errdefer parsedJson.deinit();

        const root = switch (parsedJson.value) {
            .object => |obj| obj,
            else => return error.InvalidRequest,
        };

        const method_value = root.get("method") orelse return error.MissingMethod;
        const method = switch (method_value) {
            .string => |str| str,
            else => return error.InvalidMethod,
        };

        const params: ?Params = blk: {
            const params_value = root.get("params") orelse break :blk null;
            switch (params_value) {
                .array => |arr| break :blk Params.fromArray(arr),
                .object => |obj| break :blk Params.fromObject(obj),
                else => return error.InvalidParams,
            }
        };
        const id: ?RequestId = blk: {
            const id_value = root.get("id") orelse break :blk null;
            switch (id_value) {
                .string => |str_id| break :blk RequestId{ .string = str_id },
                .integer => |int_id| break :blk RequestId{ .number = int_id },
                .null => break :blk null,
                else => return error.InvalidID,
            }
        };

        return RequestObject{
            .jsonrpc = JsonRpcVersion.v2,
            .method = method,
            .params = params,
            .id = id,
            ._parsed_data = parsedJson,
        };
    }

    pub fn toJson(self: RequestObject, allocator: Allocator) ![]const u8 {
        var jsonString = std.ArrayList(u8).init(allocator);
        errdefer jsonString.deinit();

        var jsonObject = json.ObjectMap.init(allocator);
        defer jsonObject.deinit();

        try jsonObject.put("jsonrpc", json.Value{ .string = self.jsonrpc.toString() });
        try jsonObject.put("method", json.Value{ .string = self.method });
        if (self.params) |params| {
            const paramsValue = params.toJson();
            try jsonObject.put("params", paramsValue);
        }

        if (self.id) |id| {
            try jsonObject.put("id", id.toJson());
        }

        const jsonValue = json.Value{ .object = jsonObject };
        json.stringify(jsonValue, .{}, jsonString.writer()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        return try jsonString.toOwnedSlice();
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
    serverError: i64,

    /// Returns the value of the error code.
    pub fn value(self: ErrorCode) i64 {
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
    /// Integer indicates the error that occurred
    code: ErrorCode,
    /// Short description about the error
    message: []const u8,
    /// We can attach additional informations about the errors
    data: ?json.Value = null,

    pub fn fromJsonObject(json_value: json.Value) !ErrorObject {
        switch (json_value) {
            .object => |obj| {
                const code: ErrorCode = blk: {
                    const code_value = obj.get("code") orelse return error.MissingErrorCode;
                    switch (code_value) {
                        .integer => |code| break :blk try ErrorCode.fromValue(code),
                        else => return error.InvalidErrorCode,
                    }
                };

                const message = blk: {
                    const message_value = obj.get("message") orelse return error.MissingErrorMessage;
                    switch (message_value) {
                        .string => |msg| break :blk msg,
                        else => return error.InvalidErrorMessage,
                    }
                };

                const data: ?json.Value = obj.get("data");

                return .{
                    .code = code,
                    .message = message,
                    .data = data,
                };
            },
            else => return error.InvalidErrorObject,
        }
    }

    pub fn toJson(self: ErrorObject, allocator: Allocator) ![]u8 {
        var jsonString = std.ArrayList(u8).init(allocator);
        errdefer jsonString.deinit();
        var jsonObject = json.ObjectMap.init(allocator);
        defer jsonObject.deinit();

        try jsonObject.put("code", json.Value{ .integer = self.code.value() });
        try jsonObject.put("message", json.Value{ .string = self.message });
        if (self.data) |data| {
            try jsonObject.put("data", data);
        }

        const jsonValue = json.Value{ .object = jsonObject };
        json.stringify(jsonValue, .{}, jsonString.writer()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        return try jsonString.toOwnedSlice();
    }
};

pub const ResponseObject = union(enum) {
    ok: struct {
        /// Protocol version
        jsonrpc: JsonRpcVersion,
        /// Request Id
        id: RequestId,
        /// Result is determined by the method invoked on the server
        result: ?json.Value,
        _parsed_data: json.Parsed(json.Value),
    },
    err: struct {
        jsonrpc: JsonRpcVersion,
        id: ?RequestId,
        @"error": ErrorObject,
        _parsed_data: json.Parsed(json.Value),
    },

    pub fn fromSlice(allocator: Allocator, jsonString: []const u8) !ResponseObject {
        const parsedJson = try json.parseFromSlice(json.Value, allocator, jsonString, .{});
        errdefer parsedJson.deinit();

        const root = switch (parsedJson.value) {
            .object => |obj| obj,
            else => return error.InvalidResponse,
        };

        const error_object_value = root.get("error");
        if (error_object_value) |err_obj| {
            const id: ?RequestId = blk: {
                const id_value = root.get("id") orelse break :blk null;
                switch (id_value) {
                    .string => |str_id| break :blk RequestId{ .string = str_id },
                    .integer => |int_id| break :blk RequestId{ .number = int_id },
                    .null => break :blk null,
                    else => return error.InvalidID,
                }
            };
            const error_object = try ErrorObject.fromJsonObject(err_obj);

            return .{ .err = .{
                .jsonrpc = JsonRpcVersion.v2,
                .id = id,
                .@"error" = error_object,
                ._parsed_data = parsedJson,
            } };
        } else {
            const id: RequestId = blk: {
                const id_value = root.get("id") orelse return error.MissingID;
                switch (id_value) {
                    .string => |str_id| break :blk RequestId{ .string = str_id },
                    .integer => |int_id| break :blk RequestId{ .number = int_id },
                    else => return error.MissingID,
                }
            };
            const result: ?json.Value = root.get("result");
            return .{ .ok = .{
                .jsonrpc = JsonRpcVersion.v2,
                .id = id,
                .result = result,
                ._parsed_data = parsedJson,
            } };
        }

        return error.InvalidResponse;
    }

    pub fn toJson(self: ResponseObject, allocator: Allocator) ![]const u8 {
        var jsonString = std.ArrayList(u8).init(allocator);
        errdefer jsonString.deinit();
        var jsonObject = json.ObjectMap.init(allocator);
        defer jsonObject.deinit();

        // var inner_object = json.ObjectMap.init(allocator);
        // defer inner_object.deinit();
        switch (self) {
            .ok => |okObj| {
                try jsonObject.put("jsonrpc", json.Value{ .string = okObj.jsonrpc.toString() });
                try jsonObject.put("id", okObj.id.toJson());
                if (okObj.result) |result| {
                    try jsonObject.put("result", result);
                }
                // try jsonObject.put("ok", json.Value{ .object = inner_object });
            },
            .err => |errObj| {
                try jsonObject.put("jsonrpc", json.Value{ .string = errObj.jsonrpc.toString() });
                if (errObj.id) |id| {
                    try jsonObject.put("id", id.toJson());
                }
                try jsonObject.put("error", json.Value{ .string = try errObj.@"error".toJson(allocator) });
            },
        }

        const jsonValue = json.Value{ .object = jsonObject };
        json.stringify(jsonValue, .{}, jsonString.writer()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };

        return try jsonString.toOwnedSlice();
    }

    pub fn deinit(self: ResponseObject) void {
        switch (self) {
            .ok => |ok_response| ok_response._parsed_data.deinit(),
            .err => |err_response| err_response._parsed_data.deinit(),
        }
    }
};

pub fn MaybeBatch(comptime T: type) type {
    comptime {
        if (!isJsonRpcObject(T)) {
            @compileError("MaybeBatch only accepts RequestObject or ResponseObject types with required methods");
        }
    }

    return union(enum) {
        single: T,
        batch: std.ArrayList(T),

        const Self = @This();

        pub fn fromSlice(allocator: Allocator, slice: []const u8) !Self {
            var lines = std.mem.splitSequence(u8, slice, "\n");
            var items = std.ArrayList(T).init(allocator);
            errdefer {
                for (items.items) |*item| {
                    if (@hasDecl(T, "deinit")) {
                        item.deinit();
                    }
                }
                items.deinit();
            }

            while (lines.next()) |line| {
                const item = try T.fromSlice(allocator, line);
                try items.append(item);
            }

            if (items.items.len == 0) {
                items.deinit();
                return error.EmptyInput;
            } else if (items.items.len == 1) {
                const single_item = items.items[0];
                items.deinit();
                return Self{ .single = single_item };
            } else {
                return Self{ .batch = items };
            }
        }

        pub fn deinit(self: *Self) void {
            switch (self.*) {
                .single => |*item| {
                    if (@hasDecl(T, "deinit")) {
                        item.deinit();
                    }
                },
                .batch => |*batch| {
                    for (batch.items) |*item| {
                        if (@hasDecl(T, "deinit")) {
                            item.deinit();
                        }
                    }
                    batch.deinit();
                },
            }
        }

        pub fn get(self: Self, index: usize) ?*const T {
            return switch (self) {
                .single => |*item| if (index == 0) item else null,
                .batch => |batch| if (index < batch.items.len) &batch.items[index] else null,
            };
        }

        pub fn len(self: Self) usize {
            switch (self) {
                .single => return 1,
                .batch => |items| return items.items.len,
            }
        }

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .maybe_batch = self,
                .index = 0,
            };
        }

        pub const Iterator = struct {
            maybe_batch: *const Self,
            index: usize,

            pub fn next(self: *Iterator) ?*const T {
                defer self.index += 1;
                return self.maybe_batch.get(self.index);
            }
        };
    };
}

/// MaybeBatch only accepts RequstObject or ResponseObject
fn isJsonRpcObject(comptime T: type) bool {
    if (!@hasDecl(T, "fromSlice")) return false;
    if (!@hasDecl(T, "deinit")) return false;

    const fromSlice = @field(T, "fromSlice");
    const fromSlice_info = @typeInfo(@TypeOf(fromSlice));
    if (fromSlice_info != .@"fn") return false;

    const type_info = @typeInfo(T);
    switch (type_info) {
        .@"struct" => {
            // RequestObject
            if (@hasField(T, "jsonrpc") and @hasField(T, "method")) return true;
        },
        .@"union" => {
            // ResponseObject
            if (@hasField(T, "ok") or @hasField(T, "err")) return true;
        },
        else => return false,
    }

    return false;
}

const testing = std.testing;

test "RequestObject.fromSlice - valid request with array params" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
    ;

    var request = try RequestObject.fromSlice(allocator, json_str);
    defer request.deinit();

    try testing.expect(request.jsonrpc == .v2);
    try testing.expectEqualStrings("subtract", request.method);
    if (request.params) |params| {
        try testing.expect(params == .array);
    } else {
        std.debug.print("Missing params\n", .{});
        try testing.expect(false);
    }
    if (request.id) |id| {
        try testing.expect(id == .number);
        try testing.expectEqual(@as(i64, 1), id.number);
    } else {
        std.debug.print("Missing id\n", .{});
        try testing.expect(false);
    }
}

test "RequestObject.fromSlice - valid request with object params" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "foobar", "params": {"name": "test"}, "id": "req-123"}
    ;

    var request = try RequestObject.fromSlice(allocator, json_str);
    defer request.deinit();

    try testing.expectEqualStrings("foobar", request.method);
    try testing.expect(request.params != null);

    if (request.params) |params| {
        switch (params) {
            .object => {},
            else => try testing.expect(false),
        }
    }

    if (request.id) |id| {
        switch (id) {
            .string => |str| try testing.expectEqualStrings("req-123", str),
            else => try testing.expect(false),
        }
    } else {
        std.debug.print("Missing id\n", .{});
        try testing.expect(false);
    }
}

test "RequestObject.fromSlice - notification (no id)" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "update", "params": [1, 2, 3, 4, 5]}
    ;

    var request = try RequestObject.fromSlice(allocator, json_str);
    defer request.deinit();

    try testing.expectEqualStrings("update", request.method);
    try testing.expect(request.id == null);
    try testing.expect(request.params != null);
}

test "RequestObject.fromSlice - minimal request" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "ping"}
    ;

    var request = try RequestObject.fromSlice(allocator, json_str);
    defer request.deinit();

    try testing.expectEqualStrings("ping", request.method);
    try testing.expect(request.params == null);
    try testing.expect(request.id == null);
}

test "RequestObject.fromSlice - invalid json" {
    const allocator = testing.allocator;

    const json_str = "invalid json";

    const result = RequestObject.fromSlice(allocator, json_str);
    try testing.expectError(error.SyntaxError, result);
}

test "RequestObject.fromSlice - missing method" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "id": 1}
    ;

    const result = RequestObject.fromSlice(allocator, json_str);
    try testing.expectError(error.MissingMethod, result);
}

test "RequestObject.fromSlice - invalid method type" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": 123, "id": 1}
    ;

    const result = RequestObject.fromSlice(allocator, json_str);
    try testing.expectError(error.InvalidMethod, result);
}

test "ResponseObject.fromSlice - success response" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "result": 19, "id": 1}
    ;

    var response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit();

    switch (response) {
        .ok => |ok_resp| {
            try testing.expect(ok_resp.jsonrpc == .v2);
            switch (ok_resp.id) {
                .number => |num| try testing.expectEqual(@as(i64, 1), num),
                else => try testing.expect(false),
            }
            try testing.expect(ok_resp.result != null);
        },
        .err => try testing.expect(false),
    }
}

test "ResponseObject.fromSlice - error response" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "error": {"code": -32601, "message": "Method not found"}, "id": "1"}
    ;

    var response = try ResponseObject.fromSlice(allocator, json_str);
    defer response.deinit();

    switch (response) {
        .err => |err_resp| {
            try testing.expect(err_resp.jsonrpc == .v2);
            try testing.expectEqual(@as(i64, -32601), err_resp.@"error".code.value());
            try testing.expectEqualStrings("Method not found", err_resp.@"error".message);
        },
        .ok => try testing.expect(false),
    }
}

test "MaybeBatch.fromSlice - single request" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}
    ;

    var maybe_batch = try MaybeBatch(RequestObject).fromSlice(allocator, json_str);
    defer maybe_batch.deinit();

    switch (maybe_batch) {
        .single => |request| {
            try testing.expectEqualStrings("subtract", request.method);
        },
        .batch => try testing.expect(false),
    }
}

test "MaybeBatch.fromSlice - batch requests" {
    const allocator = testing.allocator;

    const json_str =
        \\{"jsonrpc": "2.0", "method": "sum", "params": [1,2,4], "id": "1"}
        \\{"jsonrpc": "2.0", "method": "notify_hello", "params": [7]}
        \\{"jsonrpc": "2.0", "method": "get_data", "id": "9"}
    ;

    var maybe_batch = try MaybeBatch(RequestObject).fromSlice(allocator, json_str);
    defer maybe_batch.deinit();

    switch (maybe_batch) {
        .batch => |batch| {
            try testing.expectEqual(@as(usize, 3), batch.items.len);
            try testing.expectEqualStrings("sum", batch.items[0].method);
            try testing.expectEqualStrings("notify_hello", batch.items[1].method);
            try testing.expectEqualStrings("get_data", batch.items[2].method);
        },
        .single => try testing.expect(false),
    }
}
