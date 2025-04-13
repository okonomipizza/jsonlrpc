const std = @import("std");
const posix = std.posix;

pub const JsonStream = struct {
    socket: posix.socket_t,
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !Self {
        const buf = try std.ArrayList(u8).initCapacity(allocator, 1024);

        return Self{
            .socket = socket,
            .buf = buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit();
    }

    pub fn readBuf(
        self: *Self,
    ) ![]u8 {
        try self.buf.resize(0);

        while (true) {
            try self.buf.ensureTotalCapacity(self.buf.items.len + 1024);

            // Get a slice of the unused portion of the buffer
            const read_buf = self.buf.items.ptr[self.buf.items.len..self.buf.capacity];

            // Read data into that slice
            const n = try posix.read(self.socket, read_buf);
            if (n == 0) {
                return error.Closed;
            }

            // Update the length of the ArrayList to include the newly read data
            const new_len = self.buf.items.len + n;
            try self.buf.resize(new_len);

            if (std.mem.indexOf(u8, self.buf.items, "\n")) |index| {
                const result = try self.allocator.dupe(u8, self.buf.items[0..index]);

                // Remove the processed data from the buffer (including the newline)
                std.mem.copyBackwards(u8, self.buf.items, self.buf.items[index + 1 ..]);
                try self.buf.resize(self.buf.items.len - (index + 1));

                return result;
            }
        }
    }

    pub fn writeBuf(self: *Self, msg: []const u8) !void {
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
