const std = @import("std");
const fs = std.fs;
const posix = std.posix;

const Allocator = std.mem.Allocator;
const Address = std.net.Address;
const Request = std.http.Server.Request;
const ClientMap = std.AutoHashMapUnmanaged(posix.socket_t, *Client);
const Config = @import("Config.zig");

pub const ReqHandlerMap = std.StaticStringMap(*const fn (
    Allocator,
    *const Config,
    *Request,
    []const u8,
) anyerror!void);

pub fn serve(
    gpa: Allocator,
    address: Address,
    config: *const Config,
    req_handler_map: *const ReqHandlerMap,
) !void {
    var server = Server.init(gpa, address) catch |err| {
        std.log.err("failed to initialize server: {}", .{err});
        return;
    };

    defer server.deinit(gpa);

    std.log.info("dispatch server is listening at {f}", .{address});

    while (true) {
        _ = try posix.poll(server.polls.items, -1);

        var i: usize = 0;
        while (i < server.polls.items.len) : (i += 1) {
            const poll = server.polls.items[i];
            if (poll.revents == 0) continue;

            if (poll.fd == server.listener) {
                var addr: Address = undefined;
                var addr_len: posix.socklen_t = @sizeOf(Address);

                const fd = try posix.accept(server.listener, &addr.any, &addr_len, posix.SOCK.NONBLOCK);
                try server.onConnect(gpa, fd, addr);

                std.log.debug("new connection from {f}", .{addr});
            } else {
                const client = server.clients.get(poll.fd).?;
                const status = client.onReceive(gpa, config, req_handler_map);

                if (status == .disconnected) {
                    std.log.debug("client from {f} disconnected", .{client.address});

                    server.destroyClient(gpa, poll.fd, i);
                    i -= 1;
                }
            }
        }
    }
}

const Client = struct {
    address: Address,
    stream: fs.File,
    recv_buffer: [4096]u8 = undefined,
    reader: fs.File.Reader,
    writer: fs.File.Writer,
    http_state: std.http.Server,

    pub const Status = enum {
        connected,
        disconnected,
    };

    pub fn create(gpa: Allocator, fd: posix.socket_t, address: Address) Allocator.Error!*@This() {
        const self = try gpa.create(@This());
        const stream: fs.File = .{ .handle = fd };

        self.address = address;
        self.stream = stream;
        self.reader = self.stream.reader(&self.recv_buffer);
        self.writer = self.stream.writer(&.{});

        self.http_state = .init(&self.reader.interface, &self.writer.interface);
        return self;
    }

    pub fn onReceive(
        self: *@This(),
        gpa: Allocator,
        config: *const Config,
        req_handler_map: *const ReqHandlerMap,
    ) Status {
        var request = self.http_state.receiveHead() catch |err| {
            return if (err != error.ReadFailed or self.reader.err.? != error.WouldBlock) .disconnected else .connected;
        };

        std.log.debug("Received HTTP request, method: {}, target: {s}", .{
            request.head.method,
            request.head.target,
        });

        if (request.head.method != .GET) {
            std.log.debug("Unsupported method: {} from {f} to {s}", .{
                request.head.method,
                self.address,
                request.head.target,
            });

            return .disconnected;
        }

        var iter = std.mem.splitScalar(u8, request.head.target, '?');
        const path = iter.next() orelse return .disconnected;
        const query = iter.next() orelse &.{};

        if (req_handler_map.get(path)) |handler_fn| {
            handler_fn(gpa, config, &request, query) catch return .disconnected;
        } else {
            std.log.debug("unhandled request: {s}", .{path});
        }

        return .connected;
    }

    pub fn destroy(self: *@This(), gpa: Allocator) void {
        self.stream.close();
        gpa.destroy(self);
    }
};

const Server = struct {
    const tcp_backlog: u31 = 100;
    const initial_polls_array_size: usize = 1024;

    listener: posix.socket_t,
    polls: std.ArrayList(posix.pollfd),
    clients: ClientMap,

    fn init(gpa: Allocator, address: Address) !@This() {
        const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
        errdefer posix.close(listener);

        try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.bind(listener, &address.any, address.getOsSockLen());
        try posix.listen(listener, tcp_backlog);

        var polls: std.ArrayList(posix.pollfd) = .empty;
        try polls.ensureTotalCapacity(gpa, initial_polls_array_size);
        errdefer polls.deinit(gpa);

        try polls.append(gpa, .{
            .fd = listener,
            .revents = 0,
            .events = posix.POLL.IN,
        });

        return .{
            .listener = listener,
            .polls = polls,
            .clients = .empty,
        };
    }

    fn deinit(self: *@This(), gpa: Allocator) void {
        var clients = self.clients.valueIterator();
        while (clients.next()) |ptr| {
            ptr.*.destroy(gpa);
        }

        posix.close(self.listener);

        self.clients.deinit(gpa);
        self.polls.deinit(gpa);
    }

    fn onConnect(self: *@This(), gpa: Allocator, fd: posix.socket_t, addr: Address) Allocator.Error!void {
        try self.polls.append(gpa, .{
            .fd = fd,
            .revents = 0,
            .events = posix.POLL.IN,
        });

        try self.clients.put(gpa, fd, try .create(gpa, fd, addr));
    }

    fn destroyClient(self: *@This(), gpa: Allocator, fd: posix.socket_t, index: usize) void {
        if (self.clients.fetchRemove(fd)) |entry| entry.value.destroy(gpa);
        _ = self.polls.orderedRemove(index);
    }
};
