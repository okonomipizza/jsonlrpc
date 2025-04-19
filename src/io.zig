const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
pub const RequestObject = @import("type.zig").RequestObject;
pub const ResponseObject = @import("type.zig").ResponseObject;

pub const Reader = struct {
    buf: []u8,
    pos: usize = 0,
    start: usize = 0,

    pub fn init(allocator: Allocator, size: usize) !Reader {
        const buf = try allocator.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            .buf = buf,
        };
    }

    pub fn deinit(self: *const Reader, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    pub fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
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

    fn bufferedMessage(self: *Reader) !?[]u8 {
        const buf = self.buf;
        const pos = self.pos;
        const start = self.start;

        std.debug.assert(pos >= start);
        const unprocessed = buf[start..pos];

        const newline_index = std.mem.indexOfScalar(u8, unprocessed, '\n') orelse {
            return null;
        };
        const msg = buf[start..newline_index];

        self.pos = 0;
        self.start = 0;

        return msg;
    }
};
