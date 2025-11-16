const std = @import("std");
const protocol = @import("protocol");

const PropertyHashMap = @import("../property.zig").PropertyHashMap;
const TemplateCollection = @import("../../data/TemplateCollection.zig");

const Allocator = std.mem.Allocator;
const Self = @This();

pub const EntranceInfo = struct {
    entrance_id: u32,
    state: u32,
    zone_info: ZoneInfo,

    pub fn toSyncProto(self: *const @This(), allocator: Allocator) !protocol.ByName(.HadalEntranceSync) {
        return protocol.makeProto(.HadalEntranceSync, .{
            .entrance_id = self.entrance_id,
            .state = self.state,
            .cur_zone_record = try self.zone_info.toProto(allocator),
        });
    }
};

pub const ZoneInfo = struct {
    zone_id: u32,
    begin_timestamp: i64,
    end_timestamp: i64,
    layer_record_list: std.AutoArrayHashMapUnmanaged(u32, LayerRecord),

    pub fn toProto(self: *const @This(), allocator: Allocator) !protocol.ByName(.ZoneRecord) {
        var proto = protocol.makeProto(.ZoneRecord, .{
            .zone_id = self.zone_id,
            .begin_timestamp = self.begin_timestamp,
            .end_timestamp = self.end_timestamp,
        });
        var layer_records = self.layer_record_list.iterator();
        while (layer_records.next()) |entry| {
            const layer_record = entry.value_ptr;
            try protocol.addToList(allocator, &proto, .layer_record_list, try layer_record.toProto(allocator));
        }

        return proto;
    }
};

pub const LayerRecord = struct {
    layer_index: u32,
    total_time: u32,
    avatar_id_list: []const u32,
    buddy_id: u32,
    layer_item_id: u32,

    pub fn toProto(self: *const @This(), allocator: Allocator) !protocol.ByName(.LayerRecord) {
        var proto = protocol.makeProto(.LayerRecord, .{
            .layer_index = self.layer_index,
            .total_time = self.total_time,
            .buddy_id = self.buddy_id,
            .layer_item_id = self.layer_item_id,
        });

        for (self.avatar_id_list) |avatar_id| {
            try protocol.addToList(allocator, &proto, .avatar_id_list, avatar_id);
        }

        return proto;
    }
};

entrances: PropertyHashMap(u32, EntranceInfo),

pub fn init(allocator: Allocator) Self {
    return .{
        .entrances = .init(allocator),
    };
}

pub fn getZoneInfo(
    self: *Self,
    zone_id: u32,
    templates: *const TemplateCollection,
    allocator: Allocator,
) !*ZoneInfo {
    const zone_group_id: u32 = blk: {
        for (templates.zone_info_template_tb.payload.data) |zone_info_template| {
            if (zone_info_template.zone_id == zone_id and zone_info_template.zone_group_id != 0) {
                break :blk zone_info_template.zone_group_id;
            }
        }
        break :blk 0;
    };

    if (zone_group_id == 0) {
        return error.UnknownZoneId;
    }

    const entrance_id: u32 = blk: {
        for (templates.zone_info_template_tb.payload.data) |zone_info_template| {
            if (zone_info_template.zone_id == zone_group_id) {
                break :blk zone_info_template.entrance_id;
            }
        }
        break :blk 0;
    };

    if (entrance_id == 0) {
        return error.UnknownZoneId;
    }

    if (!self.entrances.contains(entrance_id)) {
        var entrance_info: EntranceInfo = .{
            .entrance_id = entrance_id,
            .state = 3,
            .zone_info = .{
                .zone_id = zone_id,
                .begin_timestamp = std.time.timestamp() - (3600 * 24),
                .end_timestamp = std.time.timestamp() + (3600 * 24 * 14),
                .layer_record_list = .empty,
            },
        };
        for (templates.zone_info_template_tb.payload.data) |zone_info_template| {
            if (zone_info_template.zone_id == zone_id) {
                try entrance_info.zone_info.layer_record_list.put(
                    allocator,
                    zone_info_template.layer_index,
                    .{
                        .layer_index = zone_info_template.layer_index,
                        .total_time = 0,
                        .avatar_id_list = &.{},
                        .buddy_id = 0,
                        .layer_item_id = 0,
                    },
                );
            }
        }
        try self.entrances.put(entrance_id, entrance_info);
    }

    return &self.entrances.getPtr(entrance_id).?.*.zone_info;
}

pub fn isChanged(self: *const Self) bool {
    inline for (std.meta.fields(Self)) |field| {
        if (@hasDecl(@FieldType(Self, field.name), "isChanged")) {
            if (@field(self, field.name).isChanged()) return true;
        }
    }

    return false;
}

pub fn ackPlayerSync(self: *const Self, notify: *protocol.ByName(.PlayerSyncScNotify), allocator: Allocator) !void {
    var hadal_zone_sync = protocol.makeProto(.HadalZoneSync, .{});

    for (self.entrances.changed_keys.items) |changed_key| {
        if (self.entrances.get(changed_key)) |entrance_info| {
            try protocol.addToList(allocator, &hadal_zone_sync, .hadal_entrance_list, try entrance_info.toSyncProto(allocator));
        }
    }

    protocol.setFields(notify, .{
        .hadal_zone = hadal_zone_sync,
    });
}

pub fn reset(self: *Self) void {
    inline for (std.meta.fields(Self)) |field| {
        if (@hasDecl(@FieldType(Self, field.name), "reset")) {
            @field(self, field.name).reset();
        }
    }
}

pub fn deinit(self: *Self) void {
    inline for (std.meta.fields(Self)) |field| {
        if (@hasDecl(@FieldType(Self, field.name), "deinit")) {
            @field(self, field.name).deinit();
        }
    }
}
