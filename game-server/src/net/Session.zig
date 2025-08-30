const std = @import("std");
const common = @import("common");
const Globals = @import("../Globals.zig");
const PlayerInfo = @import("../logic/player/PlayerInfo.zig");
const GameMode = @import("../logic/GameMode.zig");

const Allocator = std.mem.Allocator;

packet_id_counter: u32 = 0,
player_uid: u32,
xorpad: [4096]u8 = undefined,
globals: *const Globals,
player_info: ?PlayerInfo = null,
game_mode: ?GameMode = null,

pub fn create(gpa: Allocator, uid: u32, rand_key: u64, globals: *const Globals) Allocator.Error!*@This() {
    const self = try gpa.create(@This());
    self.* = .{ .player_uid = uid, .globals = globals };

    common.random.getMtDecryptVector(rand_key, &self.xorpad);
    return self;
}

pub fn destroy(self: *@This(), gpa: Allocator) void {
    if (self.player_info != null) {
        self.player_info.?.deinit();
    }

    if (self.game_mode != null) {
        self.game_mode.?.deinit();
    }

    gpa.destroy(self);
}

pub fn nextPacketId(self: *@This()) u32 {
    self.packet_id_counter += 1;
    return self.packet_id_counter;
}
