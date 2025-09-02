const std = @import("std");
const common = @import("common");
const protocol = @import("protocol");
const Globals = @import("../Globals.zig");
const NetContext = @import("NetContext.zig");
const Session = @import("Session.zig");

const Io = std.Io;
const fs = std.fs;
const posix = std.posix;

const Address = std.net.Address;
const Allocator = std.mem.Allocator;
const ClientMap = std.AutoHashMapUnmanaged(posix.socket_t, *Client);
const SessionMap = std.AutoHashMapUnmanaged(u32, *Session);

const initial_xorpad = @embedFile("initial_xorpad.bin");

const handlers = struct {
    pub const player = @import("../handlers/player.zig");
    pub const avatar = @import("../handlers/avatar.zig");
    pub const item = @import("../handlers/item.zig");
    pub const quest = @import("../handlers/quest.zig");
    pub const buddy = @import("../handlers/buddy.zig");
    pub const misc = @import("../handlers/misc.zig");
    pub const tips = @import("../handlers/tips.zig");
    pub const collect = @import("../handlers/collect.zig");
    pub const world = @import("../handlers/world.zig");
    pub const map = @import("../handlers/map.zig");
    pub const time = @import("../handlers/time.zig");
};

const CmdId = HandledCmdIds(handlers);

const XoringWriter = struct {
    xor_start_index: ?usize = null,
    xorpad_index: ?usize = null,
    interface: Io.Writer,
    underlying_file: fs.File.Writer,
    xorpad: []const u8,

    pub fn init(buffer: []u8, xorpad: []const u8, underlying_file: fs.File.Writer) @This() {
        return .{
            .underlying_file = underlying_file,
            .xorpad = xorpad,
            .interface = .{ .buffer = buffer, .vtable = &.{ .drain = @This().drain } },
        };
    }

    pub fn pushXorStartIndex(self: *@This()) void {
        if (self.xor_start_index == null) self.xor_start_index = self.interface.end;
    }

    pub fn popXorStartIndex(self: *@This()) void {
        if (self.xor_start_index) |index| {
            const buf = self.interface.buffered()[index..];
            const xorpad_index = self.xorpad_index orelse 0;

            for (0..buf.len) |i| {
                buf[i] ^= self.xorpad[(xorpad_index + i) % 4096];
            }

            self.xor_start_index = null;
            self.xorpad_index = null;
        }
    }

    fn drain(w: *Io.Writer, data: []const []const u8, _: usize) Io.Writer.Error!usize {
        const this: *@This() = @alignCast(@fieldParentPtr("interface", w));
        const buf = w.buffered();
        w.end = 0;

        if (this.xor_start_index) |index| {
            var xorpad_index = this.xorpad_index orelse 0;

            const slice = buf[index..];
            for (0..slice.len) |i| {
                slice[i] ^= this.xorpad[xorpad_index % 4096];
                xorpad_index += 1;
            }

            this.xor_start_index = 0;
            this.xorpad_index = xorpad_index;
        }

        try this.underlying_file.interface.writeAll(buf);

        @memcpy(w.buffer[0..data[0].len], data[0]);
        w.end = data[0].len;

        return buf.len;
    }
};

const NetPacket = struct {
    const overhead_size: usize = 16;
    const head_magic: [4]u8 = .{ 0x01, 0x23, 0x45, 0x67 };
    const tail_magic: [4]u8 = .{ 0x89, 0xAB, 0xCD, 0xEF };

    reader: *Io.Reader,
    cmd_id: u16,
    head: []const u8,
    body: []const u8,

    fn decode(reader: *Io.Reader) !@This() {
        if (reader.bufferedLen() < overhead_size) return error.IncompletePacket;

        const header = try reader.peekArray(overhead_size);
        if (!std.mem.eql(u8, header[0..4], &head_magic)) return error.CorruptedPacket;

        const head_size: usize = @intCast(std.mem.readInt(u16, header[6..8], .big));
        const body_size: usize = @intCast(std.mem.readInt(u32, header[8..12], .big));

        const full_size = overhead_size + head_size + body_size;

        if (full_size > Client.recv_buffer_size) return error.TooBigPacket;
        if (reader.bufferedLen() < overhead_size + head_size + body_size) return error.IncompletePacket;
        const buffer = try reader.peek(overhead_size + head_size + body_size);

        const tail_offset = 12 + head_size + body_size;
        if (!std.mem.eql(u8, buffer[tail_offset .. tail_offset + 4], &tail_magic)) return error.CorruptedPacket;

        return .{
            .reader = reader,
            .cmd_id = std.mem.readInt(u16, buffer[4..6], .big),
            .head = buffer[12 .. 12 + head_size],
            .body = buffer[12 + head_size .. 12 + head_size + body_size],
        };
    }

    pub fn write(writer: *XoringWriter, cmd_id: u16, head: protocol.head.PacketHead, body: anytype) !void {
        const w = &writer.interface;

        try w.writeAll(&head_magic);
        try w.writeInt(u16, cmd_id, .big);
        try w.writeInt(u16, @truncate(head.pb.encodingLength()), .big);
        try w.writeInt(u32, @truncate(body.pb.encodingLength()), .big);
        try head.pb.encode(w);

        writer.pushXorStartIndex();
        try body.pb.encode(w);
        writer.popXorStartIndex();

        try w.writeAll(&tail_magic);
    }

    pub fn deinit(self: @This()) void {
        self.reader.toss(overhead_size + self.head.len + self.body.len);
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

    fn onConnect(self: *@This(), gpa: Allocator, fd: posix.socket_t, address: Address) Allocator.Error!void {
        try self.polls.append(gpa, .{
            .fd = fd,
            .revents = 0,
            .events = posix.POLL.IN,
        });

        try self.clients.put(gpa, fd, try Client.create(gpa, fd, address));
    }

    fn onDisconnect(self: *@This(), gpa: Allocator, index: usize, fd: posix.socket_t, client: *Client) void {
        client.destroy(gpa);
        _ = self.clients.remove(fd);
        _ = self.polls.orderedRemove(index);
    }

    fn deinit(self: *@This(), gpa: Allocator) void {
        posix.close(self.listener);

        var clients = self.clients.valueIterator();
        while (clients.next()) |client| {
            client.*.destroy(gpa);
        }

        self.clients.deinit(gpa);
        self.polls.deinit(gpa);
    }
};

pub const Client = struct {
    const recv_buffer_size: usize = 32 * 1024;
    const send_buffer_size: usize = 8 * 1024;

    address: Address,
    socket: fs.File,
    reader: fs.File.Reader,
    writer: XoringWriter,
    recv_buffer: [recv_buffer_size]u8,
    send_buffer: [send_buffer_size]u8,
    player_uid: ?u32,

    fn create(gpa: Allocator, fd: posix.socket_t, address: Address) Allocator.Error!*@This() {
        const self = try gpa.create(@This());
        self.address = address;
        self.socket = .{ .handle = fd };
        self.reader = self.socket.reader(&self.recv_buffer);
        self.writer = .init(&self.send_buffer, initial_xorpad, self.socket.writer(&.{}));
        self.player_uid = null;

        return self;
    }

    fn destroy(self: *@This(), gpa: Allocator) void {
        self.socket.close();
        gpa.destroy(self);
    }

    fn nextPacket(self: *@This()) !NetPacket {
        return try NetPacket.decode(&self.reader.interface);
    }

    pub fn sendPacket(self: *@This(), head: protocol.head.PacketHead, body: anytype) !void {
        try NetPacket.write(&self.writer, body.pb.getCmdId(), head, body);
    }
};

pub fn listen(gpa: Allocator, address: Address, shutdown_on_disconnect: bool, globals: *const Globals) !void {
    var server = Server.init(gpa, address) catch |err| {
        std.log.err("failed to initialize server: {}", .{err});
        return;
    };

    defer server.deinit(gpa);
    std.log.debug("game server is listening at {f}", .{address});

    var sessions: SessionMap = .empty;
    defer {
        var iter = sessions.valueIterator();
        while (iter.next()) |session| session.*.destroy(gpa);
        sessions.deinit(gpa);
    }

    main_loop: while (true) {
        _ = try posix.poll(server.polls.items, -1);

        var i: usize = 0;
        iter_polls: while (i < server.polls.items.len) : (i += 1) {
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
                client.reader.interface.fillMore() catch {
                    std.log.debug("client from {f} disconnected", .{client.address});
                    server.onDisconnect(gpa, i, poll.fd, client);
                    i -= 1;

                    if (shutdown_on_disconnect) break :main_loop;
                    continue :iter_polls;
                };

                const status: Status = while (client.reader.interface.bufferedLen() != 0) {
                    const packet = NetPacket.decode(&client.reader.interface) catch |err| {
                        if (err != error.IncompletePacket) break .force_disconnect else break .ok;
                    };

                    defer packet.deinit();

                    const status = handlePacket(gpa, &sessions, client, &packet, globals) catch |err| {
                        std.log.err(
                            "handlePacket failed for client from {f}, cmd id: {}, error: {}",
                            .{ client.address, packet.cmd_id, err },
                        );
                        continue;
                    };

                    if (status != .ok) break status;
                } else .ok;

                switch (status) {
                    .ok => client.writer.interface.flush() catch {},
                    .force_disconnect => {
                        std.log.debug("client from {f} disconnected", .{client.address});
                        server.onDisconnect(gpa, i, poll.fd, client);
                        i -= 1;
                        if (shutdown_on_disconnect) break :main_loop;
                        continue :iter_polls;
                    },
                }
            }
        }
    }
}

const Status = enum {
    ok,
    force_disconnect,
};

fn HandledCmdIds(comptime Handlers: type) type {
    @setEvalBranchQuota(1_000_000);

    var fields: []const std.builtin.Type.EnumField = &.{};

    inline for (std.meta.declarations(Handlers)) |import_decl| {
        const Module = @field(Handlers, import_decl.name);
        inline for (std.meta.declarations(Module)) |decl| {
            switch (@typeInfo(@TypeOf(@field(Module, decl.name)))) {
                .@"fn" => |fn_info| {
                    const Message = fn_info.params[1].type.?;
                    if (!@hasDecl(Message, "cmd_id")) continue;
                    if (@field(Message, "cmd_id") == protocol.DummyMessage.cmd_id) continue;

                    fields = fields ++ .{std.builtin.Type.EnumField{
                        .name = @typeName(Message),
                        .value = @field(Message, "cmd_id"),
                    }};
                },
                else => {},
            }
        }
    }

    return @Type(.{ .@"enum" = .{
        .decls = &.{},
        .tag_type = u16,
        .fields = fields,
        .is_exhaustive = true,
    } });
}

fn handlePacket(gpa: Allocator, sessions: *SessionMap, client: *Client, packet: *const NetPacket, globals: *const Globals) !Status {
    if (packet.cmd_id == protocol.ByName(.PlayerGetTokenCsReq).cmd_id) {
        return handleGetToken(client, packet, gpa, globals, sessions);
    }

    const player_uid = client.player_uid orelse {
        std.log.debug("unexpected first cmd id: {}", .{packet.cmd_id});
        return .force_disconnect;
    };

    const session = sessions.get(player_uid) orelse {
        std.log.debug("no session for player with UID: {}, disconnecting", .{player_uid});
        return .force_disconnect;
    };

    if (protocol.ByName(.PlayerLogoutCsReq).cmd_id != protocol.DummyMessage.cmd_id) {
        if (packet.cmd_id == protocol.ByName(.PlayerLogoutCsReq).cmd_id) {
            std.log.debug("received logout request for player with UID: {}", .{player_uid});
            return .force_disconnect;
        }
    }

    xorBuffer(@constCast(packet.body), &session.xorpad);

    std.log.debug(
        "received packet with Cmd ID {}, head: {X}, body: {X}",
        .{ packet.cmd_id, packet.head, packet.body },
    );

    const req_head = try protocol.protobuf.decodeMessage(protocol.head.PacketHead, packet.head, gpa);
    defer req_head.pb.deinit(gpa);

    if (std.meta.intToEnum(CmdId, packet.cmd_id)) |cmd_id_tag| {
        return dispatchPacket(client, session, gpa, cmd_id_tag, req_head, packet.body);
    } else |_| {
        std.log.warn("unhandled cmd: {?s} ({})", .{ protocol.CmdNames[packet.cmd_id], packet.cmd_id });

        if (req_head.packet_id != 0) {
            const rsp_head = protocol.head.PacketHead{
                .packet_id = session.nextPacketId(),
                .ack_packet_id = req_head.packet_id,
            };

            try client.sendPacket(rsp_head, &protocol.DummyMessage{});
        }

        return .ok;
    }
}

fn dispatchPacket(client: *Client, session: *Session, gpa: Allocator, cmd_id_tag: CmdId, head: protocol.head.PacketHead, body: []const u8) !Status {
    @setEvalBranchQuota(1_000_000);

    switch (cmd_id_tag) {
        inline else => |cmd_id| {
            inline for (comptime std.meta.declarations(handlers)) |import_decl| {
                const Module = @field(handlers, import_decl.name);
                inline for (comptime std.meta.declarations(Module)) |decl| {
                    switch (@typeInfo(@TypeOf(@field(Module, decl.name)))) {
                        .@"fn" => |fn_info| {
                            const Message = fn_info.params[1].type.?;
                            if (!@hasDecl(Message, "cmd_id")) continue;
                            if (@field(Message, "cmd_id") == protocol.DummyMessage.cmd_id) continue;

                            const handler_cmd_id: CmdId = @enumFromInt(@field(Message, "cmd_id"));

                            if (cmd_id == handler_cmd_id) {
                                const req = try protocol.protobuf.decodeMessage(Message, body, gpa);
                                defer req.pb.deinit(gpa);

                                var arena_allocator = std.heap.ArenaAllocator.init(gpa);
                                defer arena_allocator.deinit();
                                const arena = arena_allocator.allocator();

                                var context: NetContext = .{
                                    .client = client,
                                    .session = session,
                                    .gpa = gpa,
                                    .arena = arena,
                                };

                                const rsp = try @field(Module, decl.name)(&context, req);
                                defer if (@TypeOf(rsp) != void) rsp.pb.deinit(context.arena);

                                if (context.session.player_info != null) {
                                    const player_info = &context.session.player_info.?;
                                    if (player_info.hasChangedFields()) {
                                        const player_sync = try player_info.ackPlayerSync(context.arena);
                                        defer player_sync.pb.deinit(context.arena);

                                        player_info.reset();
                                        try context.notify(player_sync);
                                    }
                                }

                                if (context.session.game_mode != null) {
                                    try context.session.game_mode.?.flushNetEvents(&context);
                                }

                                if (@TypeOf(rsp) != void) {
                                    const rsp_head = protocol.head.PacketHead{
                                        .packet_id = session.nextPacketId(),
                                        .ack_packet_id = head.packet_id,
                                    };

                                    try client.sendPacket(rsp_head, &rsp);
                                }

                                std.log.debug("successfully handled message of type {s}", .{@typeName(Message)});
                                return .ok;
                            }
                        },
                        else => {},
                    }
                }
            }
        },
    }

    return .ok;
}

fn handleGetToken(client: *Client, packet: *const NetPacket, gpa: Allocator, globals: *const Globals, sessions: *SessionMap) !Status {
    if (client.player_uid != null) {
        std.log.debug(
            "PlayerGetTokenCsReq received twice from {f} (uid: {})",
            .{ client.address, client.player_uid.? },
        );
        return .force_disconnect;
    }

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();

    const arena = arena_allocator.allocator();

    xorBuffer(@constCast(packet.body), initial_xorpad);
    const req = try protocol.protobuf.decodeMessage(protocol.ByName(.PlayerGetTokenCsReq), packet.body, arena);
    const result = try handlers.player.onPlayerGetTokenCsReq(req, arena);

    try client.sendPacket(.{}, &result.rsp);
    try client.writer.interface.flush();

    if (result.params) |params| {
        const session = try Session.create(gpa, params.player_uid, params.rand_key, globals);
        try sessions.put(gpa, params.player_uid, session);
        client.player_uid = params.player_uid;
        client.writer.xorpad = &session.xorpad;
    } else {
        return .force_disconnect;
    }

    return .ok;
}

inline fn xorBuffer(data: []u8, xorpad: []const u8) void {
    for (0..data.len) |i| {
        data[i] ^= xorpad[@mod(i, 4096)];
    }
}
