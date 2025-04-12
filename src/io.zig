const std = @import("std");
const posix = std.posix;

pub const JsonStream = struct {
    buf: std.ArrayList(u8),
    arena: *std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);

        const buf = try std.ArrayList(u8).initCapacity(allocator, 1024);

        return Self{
            .buf = buf,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Self) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }

    pub fn readBuf(self: *Self, socket: posix.socket_t) ![]u8 {
        try self.buf.resize(0);

        while (true) {
            try self.buf.ensureTotalCapacity(self.buf.items.len + 1024);

            // Get a slice of the unused portion of the buffer
            const read_buf = self.buf.items.ptr[self.buf.items.len..self.buf.capacity];

            // Read data into that slice
            const n = try posix.read(socket, read_buf);
            if (n == 0) {
                return error.Closed;
            }

            // Update the length of the ArrayList to include the newly read data
            const new_len = self.buf.items.len + n;
            try self.buf.resize(new_len);

            if (std.mem.indexOf(u8, self.buf.items, "\n")) |index| {
                const result = try self.arena.allocator().dupe(u8, self.buf.items[0..index]);

                // Remove the processed data from the buffer (including the newline)
                std.mem.copyBackwards(u8, self.buf.items, self.buf.items[index + 1 ..]);
                try self.buf.resize(self.buf.items.len - (index + 1));

                return result;
            }
        }
    }

    pub fn writeBuf(self: *Self, socket: posix.socket_t, msg: []const u8) !void {
        _ = self;
        var pos: usize = 0;
        while (pos < msg.len) {
            const written = try posix.write(socket, msg[pos..]);
            if (written == 0) {
                return error.Closed;
            }
            pos += written;
        }
    }
};
