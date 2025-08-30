const std = @import("std");
const Base64Decoder = std.base64.standard.Decoder;

const Self = @This();
const xorpad_size = 4096;
pub const defaults = @embedFile("gameserver_config.default.zon");

udp_addr: []const u8,
udp_port: u16,
shutdown_on_disconnect: bool,
