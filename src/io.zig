const std = @import("std");
const os = std.os;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const JsonRpcVersion = @import("type.zig").JsonRpcVersion;

const RequestObject = @import("type.zig").RequestObject;
const ResponseObject = @import("type.zig").ResponseObject;
const MaybeBatch = @import("type.zig").MaybeBatch;

const Client = @import("server.zig").Client;

const BATCH_COUNT_LENGTH: usize = 4;
const MESSAGE_LENGTH: usize = 4;

const READ_TIMEOUT_MS = 60_000;

/// JsonStream can only accept RequestObject and ResponseObject as type parameters.
/// The reader type (R) and writer type (W) must be different from each other.
/// Valid combinations are:
/// - R: RequestObject, W: ResponseObject
/// - R: ResponseObject, W: RequestObject
pub fn JsonStream(comptime R: type, comptime W: type) type {
    // Define the list of supported types
    const supported_types = [_]type{ RequestObject, ResponseObject };

    comptime {
        // Check if R is supported
        var r_supported = false;
        for (supported_types) |supported_type| {
            if (R == supported_type) {
                r_supported = true;
                break;
            }
        }
        if (!r_supported) {
            @compileError("Reader only supports RequestObject and ResponseObject, got: " ++ @typeName(R));
        }

        // Check if W is supported
        var w_supported = false;
        for (supported_types) |supported_type| {
            if (W == supported_type) {
                w_supported = true;
                break;
            }
        }
        if (!w_supported) {
            @compileError("Writer only supports RequestObject and ResponseObject, got: " ++ @typeName(W));
        }

        // Check that R and W are different types
        if (R == W) {
            @compileError("Reader and Writer types must be different. Both cannot be " ++ @typeName(R));
        }
    }

    return struct {
        socket: posix.socket_t,
        address: std.net.Address,

        reader: Reader(R),

        to_write: []posix.iovec_const,
        write_start_index: usize,

        allocator: Allocator,
        write_iovec_list: std.ArrayList(posix.iovec_const),
        write_buffers: ?WriteBuffers,

        const Self = @This();

        const WriteBuffers = struct {
            msg_num_buf: [BATCH_COUNT_LENGTH]u8,
            // This is where store length of each messages in serialized_msgs
            length_buffers: [][MESSAGE_LENGTH]u8,
            serialized_msgs: [][]const u8,

            fn deinit(self: *WriteBuffers, allocator: Allocator) void {
                for (self.serialized_msgs) |msg| {
                    allocator.free(msg);
                }
                allocator.free(self.serialized_msgs);
                allocator.free(self.length_buffers);
            }
        };

        pub fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address, buf_size: usize) !Self {
            const reader = try Reader(R).init(allocator, buf_size);
            const iovec_list = std.ArrayList(posix.iovec_const).init(allocator);

            return .{
                .socket = socket,
                .address = address,
                .reader = reader,
                .to_write = &.{},
                .write_iovec_list = iovec_list,
                .write_buffers = null,
                .write_start_index = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *const Self, allocator: Allocator) void {
            self.reader.deinit(allocator);
            self.write_iovec_list.deinit();
        }

        pub fn readMessage(self: *Self, allocator: Allocator) !?MaybeBatch(R) {
            self.reader.readMessages(allocator, self.socket) catch |err| switch (err) {
                error.WouldBlock => return null,
                else => return err,
            };

            return self.reader.data;
        }

        pub fn writeMessage(self: *Self, messages: MaybeBatch(W), epoll: ?*Epoll, cliet: ?*Client) !void {
            try self.prepareWriteData(self.allocator, messages);

            // Write all data using vectored I/O
            return self.writeAllVectoredNonBlocking(epoll, cliet);
        }

        /// writeMessage can write only data type MaybeBatch(T)
        /// The data accepted will convert to iovec.
        /// Message Protocol
        /// [message num: 4bytes] | [message1 len: 4bytes] | [message1 data: N bytes] | ...
        fn prepareWriteData(self: *Self, allocator: Allocator, messages: MaybeBatch(W)) !void {
            var iovec_list = std.ArrayList(posix.iovec_const).init(allocator);

            // Prepare buffer for message count header
            var msg_num_buf: [BATCH_COUNT_LENGTH]u8 = undefined;
            std.mem.writeInt(u32, &msg_num_buf, @intCast(messages.count()), .little);

            // Convert messages to  serialized data for writing.
            const serialized_msgs = try messages.serialize(allocator);

            var length_buffers = try allocator.alloc([MESSAGE_LENGTH]u8, serialized_msgs.len);

            // Add message count header to iovec list
            try iovec_list.append(.{
                .len = BATCH_COUNT_LENGTH,
                .base = &msg_num_buf,
            });

            // Process each serialized message
            for (serialized_msgs, 0..) |msg, i| {
                std.mem.writeInt(u32, &length_buffers[i], @intCast(msg.len), .little);

                // Add message length header to iovec
                try iovec_list.append(.{
                    .len = MESSAGE_LENGTH,
                    .base = &length_buffers[i],
                });

                // Add actual message data to iovec
                try iovec_list.append(.{
                    .len = msg.len,
                    .base = msg.ptr,
                });
            }

            const write_buffers = WriteBuffers{
                .msg_num_buf = msg_num_buf,
                .length_buffers = length_buffers,
                .serialized_msgs = serialized_msgs,
            };

            self.write_iovec_list = iovec_list;
            self.write_buffers = write_buffers;
            self.to_write = iovec_list.items;
            self.write_start_index = 0;
        }

        fn writeAllVectoredNonBlocking(self: *Self, epoll: ?*Epoll, client: ?*Client) !void {
            var vec = self.to_write;
            var i = self.write_start_index;

            while (i < vec.len) {
                var n = posix.writev(self.socket, vec[i..]) catch |err| switch (err) {
                    error.WouldBlock => return {
                        if (epoll) |ep| {
                            if (client) |cl| {
                                try ep.writeMode(cl);
                            }
                        }

                        self.write_start_index = i;
                    },
                    else => return err,
                };

                while (n >= vec[i].len) {
                    n -= vec[i].len;
                    i += 1;
                    if (i >= vec.len) return;
                }
                vec[i].base += n;
                vec[i].len -= n;
            } else {
                if (epoll) |ep| {
                    if (client) |cl| {
                        try ep.readMode(cl);
                    }
                }
                return;
            }
        }
    };
}

fn Reader(comptime T: type) type {
    return struct {
        // buffer
        buf: []u8,

        // start is where next message starts at
        start: usize = 0,

        // pos is where in buf that we're read up to, any subsequent reads need
        // to start from here
        pos: usize = 0,

        // Remaining messages counts to read from the socket.
        remaining_messages: u32 = 0,

        // Data which read from the socket and deserialized.
        data: ?MaybeBatch(T),

        const Self = @This();

        pub fn init(allocator: Allocator, size: usize) !Self {
            const buf = try allocator.alloc(u8, size);

            return .{
                .buf = buf,
                .pos = 0,
                .start = 0,
                .remaining_messages = 0,
                .data = null,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.data) |maybebatch| {
                maybebatch.deinit();
            }

            allocator.free(self.buf);
        }

        pub fn hasData(self: Self) bool {
            return self.data != null;
        }

        fn parseMessageFromSlice(self: *Self, allocator: Allocator, message: []u8) !T {
            _ = self;
            return try T.fromSlice(allocator, message);
        }

        pub fn readMessages(self: *Self, allocator: Allocator, socket: posix.socket_t) !void {
            // Read message count
            self.remaining_messages = try self.readMessageCount(socket);

            // Validate that we have at least one message
            if (self.remaining_messages == 0) return error.InvalidIncoming;

            if (self.remaining_messages == 1) {
                // Single message case: read one message and wrap it as a single item
                const message = try self.readMessage(socket);
                const parsed_object: T = try self.parseMessageFromSlice(allocator, message);
                self.data = MaybeBatch(T).fromSingle(parsed_object);
            } else {
                // Batch case: read multiple messages and store them as an array
                var batch_list = std.ArrayList(T).init(allocator);
                // Process all remaining messages
                while (self.remaining_messages > 0) : (self.remaining_messages -= 1) {
                    const message = try self.readMessage(socket);
                    const parsed_object: T = try self.parseMessageFromSlice(allocator, message);
                    try batch_list.append(parsed_object);
                }

                self.data = MaybeBatch(T).fromArrayList(batch_list);
            }
        }

        /// Read message count header from socket
        fn readMessageCount(self: *Self, socket: posix.socket_t) !u32 {
            const buf = self.buf;
            const pos = self.pos;
            const start = self.start;

            std.debug.assert(start == 0 and pos >= start);

            while (true) {
                const unprocessed = buf[start..pos];
                if (unprocessed.len >= BATCH_COUNT_LENGTH) {
                    const message_num = std.mem.readInt(u32, unprocessed[0..BATCH_COUNT_LENGTH], .little);
                    self.start = pos;
                    return message_num;
                }
                const n = try posix.read(socket, buf[pos..]);
                if (n == 0) {
                    return error.Closed;
                }
                self.pos = pos + n;
            }
        }

        fn readMessage(self: *Self, socket: posix.socket_t) ![]u8 {
            var buf = self.buf;

            while (true) {
                if (try self.bufferedMessage()) |msg| {
                    return msg;
                }
                const pos = self.pos;
                const n = try posix.read(socket, buf[pos..]);
                if (n == 0) {
                    return error.Closed;
                }
                self.pos = pos + n;
            }
        }

        fn bufferedMessage(self: *Self) !?[]u8 {
            const buf = self.buf;
            const start = self.start;
            const pos = self.pos;

            std.debug.assert(pos >= start);
            const unprocessed = buf[start..pos];
            if (unprocessed.len < MESSAGE_LENGTH) {
                self.ensureSpace(MESSAGE_LENGTH - unprocessed.len) catch unreachable;
                return null;
            }

            const message_len = std.mem.readInt(u32, unprocessed[0..MESSAGE_LENGTH], .little);

            const total_len = message_len + MESSAGE_LENGTH;

            if (unprocessed.len < total_len) {
                try self.ensureSpace(total_len);
                return null;
            }

            self.start += total_len;
            return unprocessed[MESSAGE_LENGTH..total_len];
        }

        fn ensureSpace(self: *Self, space: usize) error{BufferTooSmall}!void {
            const buf = self.buf;
            if (buf.len < space) {
                return error.BufferTooSmall;
            }

            const start = self.start;
            const spare = buf.len - start;
            if (spare >= space) {
                // We have enough space to read
                return;
            }

            const unprocessed = buf[start..self.pos];
            std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
            self.start = 0;
            self.pos = unprocessed.len;
        }
    };
}

pub const Epoll = struct {
    efd: posix.fd_t,
    ready_list: [128]linux.epoll_event = undefined,

    pub fn init() !Epoll {
        const efd = try posix.epoll_create1(0);
        return .{ .efd = efd };
    }

    pub fn deinit(self: Epoll) void {
        posix.close(self.efd);
    }

    pub fn wait(self: *Epoll, timeout: i32) []linux.epoll_event {
        const count = posix.epoll_wait(self.efd, &self.ready_list, timeout);
        return self.ready_list[0..count];
    }

    pub fn addListener(self: Epoll, listener: posix.socket_t) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = 0 },
        };
        try linux.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, listener, &event);
    }

    pub fn removeListener(self: Epoll, listener: posix.socket_t) !void {
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_DEL, listener, null);
    }

    pub fn newClient(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, client.socket, &event);
    }

    pub fn readMode(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }

    pub fn writeMode(self: Epoll, client: *Client) !void {
        var event = linux.epoll_event{
            .events = linux.EPOLL.OUT,
            .data = .{ .ptr = @intFromPtr(client) },
        };
        try posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
    }
};
