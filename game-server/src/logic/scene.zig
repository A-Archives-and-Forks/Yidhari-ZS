const std = @import("std");
const protocol = @import("protocol");
const ByName = protocol.ByName;
const Allocator = std.mem.Allocator;

pub const HallScene = @import("scene/HallScene.zig");
pub const FightScene = @import("scene/FightScene.zig");
pub const HadalZoneScene = @import("scene/HadalZoneScene.zig");

pub const SceneType = enum(u32) {
    hall = 1,
    fight = 3,
    hadal_zone = 9,
};

pub const LocalPlayType = enum(u32) {
    unkown = 0,
    archive_battle = 201,
    chess_board_battle = 202,
    guide_special = 203,
    chess_board_longfihgt_battle = 204,
    level_zero = 205,
    daily_challenge = 206,
    rally_long_fight = 207,
    dual_elite = 208,
    hadal_zone = 209,
    boss_battle = 210,
    big_boss_battle = 211,
    archive_long_fight = 212,
    avatar_demo_trial = 213,
    mp_big_boss_battle = 214,
    boss_little_battle_longfight = 215,
    operation_beta_demo = 216,
    big_boss_battle_longfight = 217,
    boss_rush_battle = 218,
    operation_team_coop = 219,
    boss_nest_hard_battle = 220,
    side_scrolling_thegun_battle = 221,
    hadal_zone_alivecount = 222,
    babel_tower = 223,
    hadal_zone_bosschallenge = 224,
    s2_rogue_battle = 226,
    buddy_towerdefense_battle = 227,
    mini_scape_battle = 228,
    mini_scape_short_battle = 229,
    activity_combat_pause = 230,
    coin_brushing_battle = 231,
    turn_based_battle = 232,
    bangboo_royale = 240,
    side_scrolling_captain = 241,
    smash_bro = 242,
    pure_hollow_battle = 280,
    pure_hollow_battle_longhfight = 281,
    pure_hollow_battle_hardmode = 282,
    training_room = 290,
    map_challenge_battle = 291,
    training_root_tactics = 292,
    bangboo_dream_rogue_battle = 293,
    target_shooting_battle = 294,
    bangboo_autobattle = 295,
    mechboo_battle = 296,
    summer_surfing = 297,
    summer_shooting = 298,
    void_front_battle_boss = 299,
    void_front_battle = 300,
    void_front_buff_battle = 301,
    activity_combat_pause_annihilate = 302,
    hadal_zone_impact_battle = 303,
    mechboo_battlev2 = 304,
    operation_team_coop_stylish = 305,
};

pub const Scene = union(SceneType) {
    hall: *HallScene,
    fight: *FightScene,
    hadal_zone: *HadalZoneScene,

    pub fn toProto(self: @This(), allocator: Allocator) !ByName(.SceneData) {
        return switch (self) {
            inline else => |scene| try scene.toProto(allocator),
        };
    }

    pub fn deinit(self: @This()) void {
        return switch (self) {
            inline else => |scene| scene.destroy(),
        };
    }
};
