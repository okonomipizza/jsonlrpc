const std = @import("std");
const posix = std.posix;
const net = std.net;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tcp_demo);

const ResponseObject = @import("type.zig").ResponseObject;
const RequestObject = @import("type.zig").RequestObject;
const JsonRpcVersion = @import("type.zig").JsonRpcVersion;
const JsonStream = @import("io.zig").JsonStream;
const Reader = @import("io.zig").Reader;

// 1 minute
const READ_TIMEOUT_MS = 60_000;

const ClientList = std.DoublyLinkedList(*Client);
const ClientNode = ClientList.Node;

/// `Server` provides a server implementation for JSON-RPC protocol communication over a socket.
/// The server handles incoming client connections and processes JSON-RPC messages.
/// Custom message handling logic can be implemented by providing a message handler
/// function when initializeng the server.
pub const Server = struct {
    allocator: Allocator,

    // The number of clients we currently have connected
    connected: usize,

    // polls[0] is always our listening socket
    polls: []posix.pollfd,

    // for creating client
    client_pool: std.heap.MemoryPool(Client),

    // list of clients, only client[0..connected] are valid
    clients: []*Client,

    // This is always polls[1..] and it's used to so that we can manipulate
    // clients and client_polls together. Nesessary because polls[0] is the
    // listening socket, and we don't ever touch that.
    client_polls: []posix.pollfd,

    // clients ordered by when they will read-timeout
    read_timeout_list: ClientList,

    // for creating nodes for our read_timeout list
    client_node_pool: std.heap.MemoryPool(ClientList.Node),

    // callback function to handle message which server received
    message_handler: *const fn (client: *Client, allocator: Allocator, message: []const []const u8) anyerror!?[]ResponseObject,

    pub fn init(allocator: Allocator, max: usize, handler: *const fn (client: *Client, allocator: Allocator, message: []const []const u8) anyerror!?[]ResponseObject) !Server {
        // + 1 for the listening socket
        const polls = try allocator.alloc(posix.pollfd, max + 1);
        errdefer allocator.free(polls);

        const clients = try allocator.alloc(*Client, max);
        errdefer allocator.free(clients);

        return .{ .polls = polls, .clients = clients, .client_polls = polls[1..], .connected = 0, .allocator = allocator, .read_timeout_list = .{}, .client_pool = std.heap.MemoryPool(Client).init(allocator), .client_node_pool = std.heap.MemoryPool(ClientNode).init(allocator), .message_handler = handler };
    }

    pub fn deinit(self: *Server) void {
        self.allocator.free(self.polls);
        self.allocator.free(self.clients);
        self.client_pool.deinit();
        self.client_node_pool.deinit();
    }

    pub fn run(self: *Server, address: std.net.Address) !void {
        const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;
        const protocol = posix.IPPROTO.TCP;
        const listener = try posix.socket(address.any.family, tpe, protocol);
        defer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, 128);

        // polls[0] is reserved for our listening socket.
        self.polls[0] = .{
            .fd = listener,
            .revents = 0,
            .events = posix.POLL.IN,
        };

        var read_timeout_list = &self.read_timeout_list;

        while (true) {
            const next_timeout = self.enforceTimeout();
            // Call poll() to update the revents field of each pollfd struct in self.polls array.
            _ = try posix.poll(self.polls[0 .. self.connected + 1], next_timeout);

            if (self.polls[0].revents != 0) {
                // Listening socket is ready
                self.accept(listener) catch |err| log.err("failed to accept: {}", .{err});
            }

            var i: usize = 0;
            while (i < self.connected) {
                const revents = self.client_polls[i].revents;
                if (revents == 0) {
                    // This socket isn't ready, move on to the next one
                    i += 1;
                    continue;
                }

                var client = self.clients[i];
                if (revents & posix.POLL.IN == posix.POLL.IN) {
                    // This socket is ready to be read
                    while (true) {
                        const msg = client.readMessage(self.allocator) catch {
                            self.removeClient(i);
                            break;
                        } orelse {
                            // No more messages, but this client is still connected

                            i += 1;
                            break;
                        };
                        defer self.allocator.free(msg);

                        client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
                        read_timeout_list.remove(client.reade_timeout_node);
                        read_timeout_list.append(client.reade_timeout_node);

                        // Process incoming messages from the client
                        // This function executes the user-configured callback handler
                        // and sends back any response returned by the handler
                        // If handler returns null (no response needed), the loop breaks and moves to the next
                        const response = try self.message_handler(client, self.allocator, msg) orelse break;
                        defer self.allocator.free(response);

                        const written = client.writeMessage(self.allocator, response) catch {
                            self.removeClient(i);
                            break;
                        };

                        if (written == false) {
                            self.client_polls[i].events = posix.POLL.OUT;
                            break;
                        }
                    }
                } else if (revents & posix.POLL.OUT == posix.POLL.OUT) {
                    const written = client.writeAllVectored() catch {
                        self.removeClient(i);
                        continue;
                    };
                    if (written) {
                        self.client_polls[i].events = posix.POLL.IN;
                    }
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
        const space = self.client_polls.len - self.connected;
        for (0..space) |_| {
            var address: net.Address = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.Address);
            const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };

            const client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);
            client.* = Client.init(self.allocator, socket, address) catch |err| {
                posix.close(socket);
                log.err("failed to initialize client: {}", .{err});
                return;
            };

            client.read_timeout = std.time.milliTimestamp() + READ_TIMEOUT_MS;
            client.reade_timeout_node = try self.client_node_pool.create();
            errdefer self.client_node_pool.destroy(client.reade_timeout_node);

            client.reade_timeout_node.* = .{
                .next = null,
                .prev = null,
                .data = client,
            };
            self.read_timeout_list.append(client.reade_timeout_node);

            const connected = self.connected;
            self.clients[connected] = client;
            self.client_polls[connected] = .{
                .fd = socket,
                .revents = 0,
                .events = posix.POLL.IN,
            };
            self.connected = connected + 1;
        } else {
            self.polls[0].events = 0;
        }
    }

    fn removeClient(self: *Server, at: usize) void {
        var client = self.clients[at];
        defer {
            posix.close(client.socket);
            self.client_node_pool.destroy(client.reade_timeout_node);
            client.deinit(self.allocator);
            self.client_pool.destroy(client);
        }

        const last_index = self.connected - 1;
        self.clients[at] = self.clients[last_index];
        self.client_polls[at] = self.client_polls[last_index];
        self.connected = last_index;

        self.polls[0].events = posix.POLL.IN;

        self.read_timeout_list.remove(client.reade_timeout_node);
    }
};

pub const Client = struct {
    socket: posix.socket_t,
    address: std.net.Address,

    reader: Reader,

    write_vec: []posix.iovec_const,
    write_vec_index: usize,
    serialized_responses: [][]u8,

    read_timeout: i64,

    reade_timeout_node: *ClientNode,

    fn init(allocator: Allocator, socket: posix.socket_t, address: std.net.Address) !Client {
        const reader = try Reader.init(allocator, 4096);
        errdefer reader.deinit(allocator);

        const write_vec = try allocator.alloc(posix.iovec_const, 0);
        errdefer allocator.free(write_vec);

        const serialized_responses = try allocator.alloc([]u8, 0);
        errdefer allocator.free(serialized_responses);

        return .{
            .reader = reader,
            .socket = socket,
            .address = address,

            .write_vec = write_vec,
            .serialized_responses = serialized_responses,
            .write_vec_index = 0,
            .read_timeout = 0, // let the server set this
            .reade_timeout_node = undefined, // hack/ugly, let the server set this when init returns
        };
    }

    fn deinit(self: *const Client, allocator: Allocator) void {
        self.reader.deinit(allocator);

        for (self.serialized_responses) |serialized| {
            allocator.free(serialized);
        }
        allocator.free(self.serialized_responses);
        allocator.free(self.write_vec);
    }

    // arraylistをtoOwnedSliceにして返せるようにする。
    fn readMessage(self: *Client, allocator: Allocator) !?[][]u8 {
        return self.reader.readMessage(allocator, self.socket) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
    }

    fn writeMessage(self: *Client, allocator: Allocator, responses: []ResponseObject) !bool {
        if (self.write_vec.len > 0) {
            return error.PendingMessage;
        }

        if (self.write_vec.len < responses.len) {
            self.write_vec = try allocator.realloc(self.write_vec, responses.len);
            self.serialized_responses = try allocator.realloc(self.serialized_responses, responses.len);
        }

        for (responses, 0..) |response, i| {
            self.serialized_responses[i] = try response.serialize(allocator);
        }

        for (self.serialized_responses, 0..) |serialized, i| {
            self.write_vec[i] = posix.iovec_const{
                .base = serialized.ptr,
                .len = serialized.len,
            };
        }

        self.write_vec_index = 0;
        return try self.writeAllVectored();
    }

    fn writeAllVectored(self: *Client) !bool {
        while (self.write_vec_index < self.write_vec.len) {
            const n = posix.writev(self.socket, self.write_vec[self.write_vec_index..]) catch |err| switch (err) {
                error.WouldBlock => return false,
                else => return err,
            };

            if (n == 0) {
                return error.Closed;
            }

            // Process written bytes
            var remaining = n;
            while (remaining > 0 and self.write_vec_index < self.write_vec.len) {
                const vec = &self.write_vec[self.write_vec_index];
                if (remaining >= vec.len) {
                    // This vector is completely consumed
                    remaining -= vec.len;
                    self.write_vec_index += 1;
                } else {
                    // This vector is partially consumed
                    vec.base += @intCast(remaining);
                    vec.len -= @intCast(remaining);
                    remaining = 0;
                }
            }

            // If we've processed all vectors, we're done
            if (self.write_vec_index >= self.write_vec.len) {
                return true;
            }
        }

        // All data has been written
        return true;
    }
};
