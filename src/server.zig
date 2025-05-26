const Epoll = @import("io.zig").Epoll;
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const JsonStream = @import("io.zig").JsonStream;
const MaybeBatch = @import("type.zig").MaybeBatch;
const Reader = @import("io.zig").Reader;
const RpcClient = @import("client.zig").RpcClient;
const RequestObject = @import("type.zig").RequestObject;
const ResponseObject = @import("type.zig").ResponseObject;

const READ_TIMEOUT_MS = 60_000;

const ClientList = std.DoublyLinkedList(*Client);
const ClientNode = ClientList.Node;

pub const Client = struct {
    loop: *Epoll,

    socket: posix.socket_t,
    address: std.net.Address,

    stream: JsonStream(RequestObject, ResponseObject),

    read_timeout: i64,
    read_timeout_node: *ClientNode,

    fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address, loop: *Epoll) !Client {
        const stream = try JsonStream(RequestObject, ResponseObject).init(allocator, socket, address, 4096);

        return .{
            .loop = loop,
            .stream = stream,
            .socket = socket,
            .address = address,
            .read_timeout = 0,
            .read_timeout_node = undefined,
        };
    }

    fn deinit(self: *const Client, allocator: Allocator) void {
        self.stream.deinit(allocator);
    }

    fn readMessage(self: *Client, allocator: Allocator) !?MaybeBatch(RequestObject) {
        return self.stream.readMessage(allocator) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    fn writeMessage(self: *Client, msg: MaybeBatch(RequestObject)) !void {
        try self.stream.writeMessage(msg, self.loop, self);
    }
};
