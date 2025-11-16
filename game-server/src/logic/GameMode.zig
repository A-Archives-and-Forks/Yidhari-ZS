const std = @import("std");
const protocol = @import("protocol");

const Globals = @import("../Globals.zig");
const PlayerInfo = @import("player/PlayerInfo.zig");
const HallScene = @import("scene/HallScene.zig");
const FightScene = @import("scene/FightScene.zig");
const HadalZoneScene = @import("scene/HadalZoneScene.zig");
const Dungeon = @import("Dungeon.zig");
const TemplateCollection = @import("../data/TemplateCollection.zig");
const Allocator = std.mem.Allocator;

const scene_base = @import("scene.zig");
const Scene = scene_base.Scene;

const Self = @This();

allocator: Allocator,
scene: Scene,
dungeon: ?Dungeon,

pub fn loadHallState(player_info: *PlayerInfo, globals: *const Globals, allocator: Allocator) !Self {
    var hall = try HallScene.create(
        player_info,
        &globals.templates,
        &globals.event_graph_map,
        allocator,
    );

    errdefer hall.destroy();
    try hall.onCreate();
    try hall.onEnter();

    return .{
        .allocator = allocator,
        .scene = .{ .hall = hall },
        .dungeon = null,
    };
}

pub fn loadFightState(
    allocator: Allocator,
    player_info: *PlayerInfo,
    templates: *const TemplateCollection,
    quest: *const TemplateCollection.templates.QuestConfigTemplate,
    avatar_ids: []const u32,
    play_type: scene_base.LocalPlayType,
) !Self {
    var dungeon = try Dungeon.init(player_info, templates, allocator);
    errdefer dungeon.deinit();

    for (avatar_ids) |id| {
        try dungeon.addAvatarFighter(id, Dungeon.PackageType.player);
    }

    // TODO: maybe pass the pointer itself at this point?
    dungeon.setDungeonQuest(quest.quest_type, quest.quest_id);

    const extended_template = try quest.getExtendedTemplate(templates);
    const scene_id = extended_template.getSceneId() orelse {
        std.log.err("GameMode.loadFightState: got non-fight quest config, id: {}", .{quest.quest_id});
        return error.InvalidQuestType;
    };

    return .{
        .allocator = allocator,
        .scene = .{ .fight = try FightScene.create(scene_id, play_type, allocator) },
        .dungeon = dungeon,
    };
}

const hadal_static_zone_group: u32 = 61;
const hadal_periodic_zone_group: u32 = 62;
const hadal_periodic_zone_id: u32 = 62001;
const hadal_periodic_with_rooms_zone_id: u32 = 62010;
const hadal_zone_bosschallenge_zone_group: u32 = 69;
const hadal_zone_bosschallenge_zone_id: u32 = 69001;

pub fn loadHadalZoneState(
    player_info: *PlayerInfo,
    templates: *const TemplateCollection,
    first_room_avatars: []const u32,
    second_room_avatars: []const u32,
    first_room_buddy_id: u32,
    second_room_buddy_id: u32,
    zone_id: u32,
    layer_index: u32,
    room_index: u32,
    layer_item_id: u32,
    allocator: Allocator,
) !Self {
    var dungeon = try Dungeon.init(player_info, templates, allocator);
    errdefer dungeon.deinit();

    for (first_room_avatars) |id| {
        try dungeon.addAvatarFighter(id, Dungeon.PackageType.player);
    }

    for (second_room_avatars) |id| {
        try dungeon.addAvatarFighter(id, Dungeon.PackageType.player);
    }

    if (first_room_buddy_id != 0) {
        try dungeon.addBuddyFighter(first_room_buddy_id, Dungeon.PackageType.player);
    }

    if (second_room_buddy_id != 0) {
        try dungeon.addBuddyFighter(second_room_buddy_id, Dungeon.PackageType.player);
    }

    var last_digits: [2]u32 = @splat(0);
    var i: u32 = zone_id;
    while (i != 0) : (i /= 10) {
        last_digits[1] = last_digits[0];
        last_digits[0] = i % 10;
    }
    const zone_group = last_digits[0] * 10 + last_digits[1];

    const layer_id: u32 = switch (zone_group) {
        hadal_static_zone_group => (zone_id * 100) + layer_index,
        hadal_periodic_zone_group => switch (room_index) {
            0 => (hadal_periodic_zone_id * 100) + layer_index,
            else => (hadal_periodic_with_rooms_zone_id * 100) + (layer_index * 10) + room_index,
        },
        hadal_zone_bosschallenge_zone_group => hadal_zone_bosschallenge_zone_id * 100 + layer_index,
        else => 0,
    };

    if (layer_id == 0) return error.InvalidZoneId;

    // TODO: get time period from ZoneInfoTemplate and use it.
    // TODO: get weather from LayerInfoTemplate and use it.

    const hadal_zone_quest_template = templates.getConfigByKey(.hadal_zone_quest_template_tb, layer_id) orelse return error.MissingQuestForLayer;
    const quest_config_template = templates.getConfigByKey(.quest_config_template_tb, hadal_zone_quest_template.quest_id) orelse return error.MissingQuestForLayer;
    dungeon.setDungeonQuest(
        quest_config_template.quest_type,
        @intCast(hadal_zone_quest_template.quest_id),
    );

    return .{
        .allocator = allocator,
        .scene = .{ .hadal_zone = try HadalZoneScene.create(
            layer_id,
            zone_id,
            layer_index,
            room_index,
            layer_item_id,
            first_room_avatars,
            second_room_avatars,
            first_room_buddy_id,
            second_room_buddy_id,
            allocator,
        ) },
        .dungeon = dungeon,
    };
}

pub fn flushNetEvents(self: *Self, context: anytype) !void {
    try self.flushTransitionEvent(context);

    switch (self.scene) {
        inline else => |scene| {
            if (@hasDecl(std.meta.Child(@TypeOf(scene)), "flushNetEvents")) {
                try scene.flushNetEvents(context);
            }
        },
    }
}

fn flushTransitionEvent(self: *Self, context: anytype) !void {
    switch (self.scene) {
        inline else => |scene| {
            if (scene.clearTransitionState()) {
                var enter_notify = protocol.makeProto(.EnterSceneScNotify, .{
                    .scene = try scene.toProto(context.arena),
                });

                if (self.dungeon) |dungeon| {
                    protocol.setFields(&enter_notify, .{
                        .dungeon = try dungeon.toProto(context.arena),
                    });
                }

                try context.notify(enter_notify);
            }
        },
    }
}

pub fn deinit(self: *Self) void {
    self.scene.deinit();

    if (self.dungeon != null) {
        self.dungeon.?.deinit();
        self.dungeon = null;
    }
}
