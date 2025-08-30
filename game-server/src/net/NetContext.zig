const std = @import("std");
const Client = @import("gateway.zig").Client;
const Session = @import("Session.zig");
const protocol = @import("protocol");

const Allocator = std.mem.Allocator;

client: *Client,
session: *Session,
gpa: Allocator,
arena: Allocator,

pub fn notify(self: *@This(), ntf: anytype) !void {
    const head = protocol.head.PacketHead{
        .packet_id = self.session.nextPacketId(),
        .ack_packet_id = 0,
    };

    try self.client.sendPacket(head, ntf);
}
