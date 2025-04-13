const std = @import("std");
const posix = std.posix;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;

pub const JsonStream = struct {
    socket: posix.socket_t,
    reader: Reader,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !JsonStream {
        const reader = try Reader.init(allocator, socket);

        return JsonStream{
            .socket = socket,
            .reader = reader,
        };
    }

    pub fn deinit(self: *JsonStream) void {
        self.reader.deinit();
    }

    pub fn readRequest(self: *JsonStream, allocator: std.mem.Allocator) ![]RequestObject {
        var request = std.ArrayList(RequestObject).init(allocator);
        errdefer request.deinit();

        var messages = std.ArrayList([]u8).init(allocator);
        defer {
            for (messages.items) |msg| {
                allocator.free(msg);
            }
            messages.deinit();
        }

        try self.reader.read(allocator, &messages);

        for (messages.items) |msg| {
            std.debug.print("request: {s}\n", .{msg});
        }

        try request.ensureTotalCapacity(messages.items.len);
        for (messages.items) |message| {
            const request_obj = try RequestObject.fromSlice(allocator, message);
            try request.append(request_obj);
        }

        return request.toOwnedSlice();
    }

    pub fn readResponse(self: *JsonStream, allocator: std.mem.Allocator) ![]ResponseObject {
        var response = std.ArrayList(ResponseObject).init(allocator);
        errdefer response.deinit();

        var messages = std.ArrayList([]u8).init(allocator);
        defer {
            for (messages.items) |msg| {
                allocator.free(msg);
            }
            messages.deinit();
        }

        try self.reader.read(allocator, &messages);

        try response.ensureTotalCapacity(messages.items.len);
        for (messages.items) |message| {
            const response_obj = try ResponseObject.fromSlice(allocator, message);
            try response.append(response_obj);
        }

        return response.toOwnedSlice();
    }

    pub fn write(self: *JsonStream, msg: []const u8) !void {
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

pub const Reader = struct {
    buf: std.ArrayList(u8),
    socket: posix.socket_t,

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !Reader {
        const buf = try std.ArrayList(u8).initCapacity(allocator, 1024);

        return Reader{
            .buf = buf,
            .socket = socket,
        };
    }

    fn deinit(self: *Reader) void {
        self.buf.deinit();
    }

    fn read(self: *Reader, allocator: std.mem.Allocator, result_buf: *std.ArrayList([]u8)) !void {
        var buf = &self.buf;

        // If the buffer is empty, read from socket
        if (buf.items.len == 0) {
            try buf.ensureTotalCapacity(1024);
            const read_buf = buf.items.ptr[0..buf.capacity];

            const n = try posix.read(self.socket, read_buf);
            if (n == 0) {
                return error.Closed;
            }

            try buf.resize(n);
        }

        while (true) {
            if (std.mem.indexOfScalar(u8, buf.items, '\n')) |index| {
                std.debug.print("n\n", .{});
                const message = try allocator.dupe(u8, buf.items[0..index]);
                try result_buf.append(message);

                // Remove processed message from buffer
                if (index + 1 < buf.items.len) {
                    const unprocessed = buf.items[index + 1 ..];
                    std.mem.copyForwards(u8, buf.items[0..], unprocessed);
                    try buf.resize(buf.items.len - (index + 1));

                    continue;
                } else {
                    return;
                }
            }

            const old_len = buf.items.len;
            try buf.ensureTotalCapacity(old_len + 1024);
            const read_buf = buf.items.ptr[old_len..buf.capacity];

            const n = try posix.read(self.socket, read_buf);
            if (n == 0) {
                return error.Closed;
            }

            try buf.resize(old_len + n);
        }
    }
};
