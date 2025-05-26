const std = @import("std");
const net = std.net;
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

const jsonlrpc = @import("jsonlrpc");
const JsonStream = jsonlrpc.JsonStream;
const RequestObject = jsonlrpc.RequestObject;
const ResponseObject = jsonlrpc.ResponseObject;
const MaybeBatch = jsonlrpc.MaybeBatch;
const Client = jsonlrpc.Client;
const Epoll = jsonlrpc.Epoll;

const log = std.log.scoped(.tcp_demo);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, 4096);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);
    try server.run(address);
    std.debug.print("STOPPED\n", .{});
}

const READ_TIMEOUT_MS = 60_000;

const ClientList = std.DoublyLinkedList(*Client);
const ClientNode = ClientList.Node;

const Server = struct {
    max: usize,

    loop: Epoll,

    allocator: Allocator,

    connected: usize,

    read_timeout_list: ClientList,

    client_pool: std.heap.MemoryPool(Client),
    client_node_pool: std.heap.MemoryPool(ClientList.Node),

    fn init(allocator: Allocator, max: usize) !Server {
        const loop = try Epoll.init();
        errdefer loop.deinit();

        const clients = try allocator.alloc(*Client, max);
        errdefer allocator.free(clients);

        return .{
            .max = max,
            .loop = loop,
            .connected = 0,
            .allocator = allocator,
            .read_timeout_list = .{},
            .client_pool = std.heap.MemoryPool(Client).init(allocator),
            .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator),
        };
    }

    fn deinit(self: *Server) void {
        self.loop.deinit();
        self.client_pool.deinit();
        self.client_node_pool.deinit();
    }

    fn run(self: *Server, address: std.net.Address) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);
        var read_timeout_list = &self.read_timeout_list;

        try self.loop.addListener(listener);

        while (true) {
            const next_timeout = self.enforceTimeout();
            const ready_events = self.loop.wait(next_timeout);
            for (ready_events) |ready| {
                switch (ready.data.ptr) {
                    0 => self.accept(listener) catch |err| log.err("failed to accept: {}", .{err}),
                    else => |nptr| {
                        const events = ready.events;
                        const client: *Client = @ptrFromInt(nptr);

                        if (events & linux.EPOLL.IN == linux.EPOLL.IN) {
                            while (true) {
                                const msg = client.readMessage(self.allocator) catch {
                                    self.closeClient(client);
                                    break;
                                } orelse break;

                                client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
                                read_timeout_list.remove(client.read_timeout_node);
                                read_timeout_list.append(client.read_timeout_node);

                                // Echo
                                msg.print();
                                // client.writeMessage(msg) catch {
                                //     self.closeClient(client);
                                //     break;
                                // };
                            }
                        } else if (events & linux.EPOLL.OUT == linux.EPOLL.OUT) {
                            client.write() catch self.closeClient(client);
                        }
                    },
                }
            }
        }
    }

    fn enforceTimeout(self: *Server) i32 {
        const now = std.time.milliTimestamp();
        var node = self.read_timeout_list.first;
        while (node) |n| {
            const client = n.data;
            const diff = client.read_timeout - now;
            if (diff > 0) {
                return @intCast(diff);
            }

            posix.shutdown(client.socket, .recv) catch {};
            node = n.next;
        } else {
            return -1;
        }
    }

    fn accept(self: *Server, listener: posix.socket_t) !void {
        const space = self.max - self.connected;
        for (0..space) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);
            client.* = Client.init(self.allocator, socket, address, &self.loop) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };
            errdefer client.deinit(self.allocator);

            client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
            client.read_timeout_node = try self.client_node_pool.create();
            errdefer self.client_node_pool.destroy(client.read_timeout_node);

            client.read_timeout_node.* = .{
                .next = null,
                .prev = null,
                .data = client,
            };
            self.read_timeout_list.append(client.read_timeout_node);
            self.connected += 1;
        } else {
            try self.loop.removeListener(listener);
        }
    }

    fn closeClient(self: *Server, client: *Client) void {
        self.read_timeout_list.remove(client.read_timeout_node);

        posix.close(client.socket);
        self.client_node_pool.destroy(client.read_timeout_node);
        client.deinit(self.allocator);
        self.client_pool.destroy(client);
    }
};
