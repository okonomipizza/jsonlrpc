const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;

/// `Reader` provides buffered reading functionality for socket communication.
/// It handles reading messages line by line from a socket, with internal buffer
/// management to efficiently process incoming data.
pub const Reader = struct {
    /// Buffer that stores incoming data from the socket
    buf: []u8,
    /// Current position within the buffer where new data will be written
    pos: usize = 0,
    /// Position marking where reading started (for tracking purposes)
    start: usize = 0,
    /// Flag indicating whether there are no more messages to process
    /// When true, the reader will stop processing after the current message
    no_msg_to_response: bool,

    pub fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            .buf = buf,
            .no_msg_to_response = false,
        };
    }

    pub fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    /// Reads complete messages from the socket.
    ///
    /// This function reads data from the socket into the ineternal buffer and
    /// extracts complete messages (lines terminated by `\n`).
    /// Each message string is expected to be parseable as JSON.
    pub fn readMessage(self: *Reader, allocator: Allocator, socket: posix.socket_t) ![][]u8 {
        var buf = self.buf;
        var messages = std.ArrayList([]u8).init(allocator);
        while (true) {
            if (try self.bufferedMessage()) |msg| {
                const message_copy = try messages.allocator.dupe(u8, msg);
                try messages.append(message_copy);
                // Return when we don't have nothing to read.
                if (self.no_msg_to_response) return try messages.toOwnedSlice();

                continue;
            }
            const pos = self.pos;
            const n = try posix.read(socket, buf[pos..]);
            if (n == 0) {
                return error.Closed;
            }

            self.pos = pos + n;
        }
    }

    /// Extracts a single complete message from the buffer if available.
    ///
    /// This function looks for a complete message (line terminated by `\n`)
    /// in the current buffer.
    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        // Compacts the buffer by moving unprocessed data to the beggining.
        if (start > buf.len / 2) {
            const unprocessed_len = pos - start;
            std.mem.copyForwards(u8, buf[0..unprocessed_len], buf[start..pos]);
            self.pos = unprocessed_len;
            self.start = 0;

            return self.bufferedMessage();
        }

        // The current position must always be at or after the start position.
        std.debug.assert(pos >= start);

        // Find the position of the first newline character in the current unprocessed portion of the buffer
        // This gives us the index relative to the `start` position.
        const relative_newline_index = std.mem.indexOfScalar(u8, buf[start..pos], '\n') orelse {
            return null;
        };

        // Convert the relative index (within the slice) to an absolute index in the full buffer
        // by adding the start offset.
        const absolute_newline_index = start + relative_newline_index;
        const msg = buf[start..absolute_newline_index]; // Extract message without '\n'.

        if (absolute_newline_index + 1 == pos and self.no_msg_to_response == false) {
            self.no_msg_to_response = true;
            return msg;
        }
        if (absolute_newline_index + 1 == pos and self.no_msg_to_response) {
            return null;
        }
        if (absolute_newline_index < pos) {
            self.start = absolute_newline_index + 1;
            return msg;
        }

        return null;
    }
};

/// `Writer` provides functionality for writing messages to a socket.
/// It includes methods for writing single message or multiple messages at once.
pub const Writer = struct {
    /// Writes a single message to the socket, ensuring the entire message is sent
    /// even if multiple write operations are required.
    pub fn writeMessage(socket: posix.socket_t, message: []const u8) !void {
        var pos: usize = 0;
        while (pos < message.len) {
            const written = try posix.write(socket, message[pos..]);
            if (written == 0) {
                return error.Closed;
            }
            pos += written;
        }
    }

    /// Writes multiple messages to the socket using vectored I/O (writev).
    ///
    /// This function uses vectored I/O to efficiently send multiple messages
    /// in a single system call when possible
    pub fn writeMessages(allocator: Allocator, socket: posix.socket_t, messages: []const []const u8) !void {
        var vec = try allocator.alloc(posix.iovec_const, messages.len);
        defer allocator.free(vec);

        for (messages, 0..) |msg, i| {
            std.debug.print("wirting {s}\n", .{msg});
            vec[i] = posix.iovec_const{
                .base = msg.ptr,
                .len = msg.len,
            };
        }

        try writeAllVectored(socket, vec);
    }

    /// Internal helper function that writes an array of iovec structures to a socket.
    ///
    /// This function handles partial writes by tracking progress through the iovec array
    /// and adjusting pointers and lengths accordingly.
    fn writeAllVectored(socket: posix.socket_t, vec: []posix.iovec_const) !void {
        var i: usize = 0;
        while (true) {
            var n = try posix.writev(socket, vec[i..]);
            while (n >= vec[i].len) {
                n -= vec[i].len;
                i += 1;
                if (i >= vec.len) return;
            }
            // pointer arithmetic
            vec[i].base += n;
            vec[i].len -= n;
        }
    }
};
