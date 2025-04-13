const std = @import("std");
const posix = std.posix;
const net = std.net;
const jsonlrpc = @import("jsonlrpc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = allocator, .n_jobs = 64 });

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const listener = try posix.socket(address.any.family, tpe, protocol);
    defer posix.close(listener);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    while (true) {
        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);
        const socket = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };

        const client = Client{ .socket = socket, .address = client_address };
        try pool.spawn(Client.handle, .{client});
    }
}

const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,

    fn handle(self: Client) void {
        self._handle() catch |err| switch (err) {
            error.Closed => {},
            else => std.debug.print("[{any}] client handle error: {}\n", .{ self.address, err }),
        };
    }

    fn _handle(self: Client) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        const socket = self.socket;

        defer posix.close(socket);
        std.debug.print("{} connected\n", .{self.address});

        const timeout = posix.timeval{ .sec = 2, .usec = 500_000 };
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));

        var stream = try jsonlrpc.JsonStream.init(allocator, socket);
        defer stream.deinit();

        const msg = try stream.readBuf();
        const deserialized = try jsonlrpc.RequestObject.fromSlice(arena_allocator, msg);
        std.debug.print("Got: {}\n", .{deserialized});

        const id = deserialized.id orelse return error.ExpectedRequestedId;

        const response_obj = jsonlrpc.ResponseObject.newSuccess(jsonlrpc.JsonRpcVersion.v2, std.json.Value{ .string = deserialized.method }, id);
        try stream.writeBuf(try response_obj.serialize(allocator));
        std.debug.print("Respond to: {}\n", .{self.address});
    }
};
