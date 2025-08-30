const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

const Config = @import("Config.zig");
const QueryIterator = @import("util.zig").QueryIterator;

pub fn handle(gpa: Allocator, config: *const Config, req: *Request, query: []const u8) !void {
    const params = Params.extract(query) catch |err| {
        std.log.warn("query_dispatch: failed to extract parameters: {}", .{err});

        const rsp = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(.{ .retcode = 70 }, .{})});
        defer gpa.free(rsp);
        try req.respond(rsp, .{});
        return;
    };

    std.log.info("query_dispatch: {f}", .{params});

    var bound_server_count: usize = 0;
    for (config.server_list) |server_config| {
        if (std.mem.eql(u8, server_config.bound_version, params.version)) {
            bound_server_count += 1;
        }
    }

    var region_list = try gpa.alloc(ServerListInfo, bound_server_count);
    defer gpa.free(region_list);

    var i: usize = 0;
    for (config.server_list) |server_config| {
        if (std.mem.eql(u8, server_config.bound_version, params.version)) {
            region_list[i] = .{
                .retcode = 0,
                .biz = "nap_global",
                .name = server_config.name,
                .title = server_config.title,
                .dispatch_url = server_config.dispatch_url,
                .ping_url = server_config.ping_url,
                .env = 2,
                .area = 2,
                .is_recommend = true,
            };
            i += 1;
        }
    }

    const rsp = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(.{
        .retcode = 0,
        .region_list = region_list,
    }, .{})});

    defer gpa.free(rsp);
    try req.respond(rsp, .{});
}

const Params = struct {
    version: []const u8,

    pub fn extract(query_str: []const u8) !@This() {
        var iter = QueryIterator.iterate(query_str);

        while (iter.next()) |pair| {
            if (std.mem.eql(u8, pair.key, "version")) {
                return .{ .version = pair.value };
            }
        }

        return error.MissingVersion;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("(version: {s})", .{self.version});
    }
};

const ServerList = struct {
    retcode: i32,
    region_list: []const ServerListInfo,
};

const ServerListInfo = struct {
    retcode: i32,
    name: []const u8,
    title: []const u8,
    biz: []const u8,
    dispatch_url: []const u8,
    ping_url: []const u8,
    env: u8,
    area: u8,
    is_recommend: bool,
};
