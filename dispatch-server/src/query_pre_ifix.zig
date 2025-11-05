const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

const Config = @import("Config.zig");
const QueryIterator = @import("util.zig").QueryIterator;

pub fn handle(gpa: Allocator, config: *const Config, req: *Request, query: []const u8) !void {
    _ = config;
    const params = Params.extract(query) catch |err| {
        std.log.warn("query_dispatch: failed query_pre_ifix extract parameters: {}", .{err});

        const rsp = try std.fmt.allocPrint(gpa, "{f}", .{std.json.fmt(.{ .retcode = 70 }, .{})});
        defer gpa.free(rsp);
        try req.respond(rsp, .{});
        return;
    };

    std.log.info("query_pre_ifix: {f}", .{params});

    const rsp = try std.fmt.allocPrint(gpa, "{{}}", .{});

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
