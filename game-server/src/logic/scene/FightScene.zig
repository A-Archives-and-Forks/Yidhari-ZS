const std = @import("std");
const protocol = @import("protocol");

const Allocator = std.mem.Allocator;
const ByName = protocol.ByName;
const String = protocol.protobuf.ManagedString;
const scene_base = @import("../scene.zig");

const LocalPlayType = scene_base.LocalPlayType;
const SceneType = scene_base.SceneType;

const Self = @This();

gpa: Allocator,
scene_id: u32,
play_type: LocalPlayType,
is_in_transition: bool = true,

pub fn create(scene_id: u32, play_type: LocalPlayType, gpa: Allocator) !*Self {
    const ptr = try gpa.create(Self);

    ptr.* = .{
        .gpa = gpa,
        .scene_id = scene_id,
        .play_type = play_type,
    };

    return ptr;
}

pub fn destroy(self: *Self) void {
    self.gpa.destroy(self);
}

pub fn clearTransitionState(self: *Self) bool {
    if (self.is_in_transition) {
        self.is_in_transition = false;
        return true;
    }

    return false;
}

pub fn toProto(self: *const Self, _: Allocator) !ByName(.SceneData) {
    const fight_data = protocol.makeProto(.FightSceneData, .{
        .scene_reward = protocol.makeProto(.SceneRewardInfo, .{}),
        .scene_perform = protocol.makeProto(.ScenePerformInfo, .{}),
    });

    return protocol.makeProto(.SceneData, .{
        .scene_id = self.scene_id,
        .scene_type = @intFromEnum(SceneType.fight),
        .play_type = @intFromEnum(self.play_type),
        .fight_scene_data = fight_data,
    });
}
