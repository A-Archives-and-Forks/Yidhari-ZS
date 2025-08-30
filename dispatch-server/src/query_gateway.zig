const App = @import("App.zig");
const Config = @import("Config.zig");
const ServerListConfig = Config.ServerListConfig;
const rsa = @import("common").rsa;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Request = std.http.Server.Request;

const QueryIterator = @import("util.zig").QueryIterator;

pub const path = "/query_gateway";

pub fn handle(gpa: Allocator, config: *const Config, req: *Request, query: []const u8) !void {
    const params = Params.extract(query) catch |err| {
        std.log.warn("query_gateway: failed to extract parameters: {}", .{err});
        // try rsp.json(.{ .retcode = 70 }, .{});
        return;
    };

    std.log.info("query_gateway: {f}", .{params});

    const server_config = for (config.server_list) |server_config| {
        if (server_config.sid == config.bound_sid and std.mem.eql(u8, server_config.bound_version, params.version)) {
            break server_config;
        }
    } else {
        std.log.warn("query_gateway: no bound server for version {s}", .{params.version});
        // try rsp.json(.{ .retcode = 71 }, .{});
        return;
    };

    const res = &config.res;
    const data = ServerDispatchData{
        .retcode = 0,
        .title = server_config.title,
        .region_name = server_config.name,
        .gateway = .{
            .ip = server_config.gateway_ip,
            .port = server_config.gateway_port,
        },
        .client_secret_key = config.client_secret_key,
        .cdn_check_url = res.cdn_check_url,
        .cdn_conf_ext = .{
            .game_res = .{
                .res_revision = res.res_revision,
                .audio_revision = res.res_revision,
                .base_url = res.res_base_url,
                .branch = res.branch,
                .md5_files = res.res_md5_files,
            },
            .design_data = .{
                .data_revision = res.data_revision,
                .base_url = res.data_base_url,
                .md5_files = res.data_md5_files,
            },
            .silence_data = .{
                .silence_revision = res.silence_revision,
                .base_url = res.silence_base_url,
                .md5_files = res.silence_md5_files,
            },
        },
        .region_ext = .{
            .func_switch = .{
                .is_kcp = 0,
                .enable_operation_log = 1,
                .enable_performance_log = 1,
            },
        },
    };

    const json_string = try std.fmt.allocPrint(gpa, "{f}", .{
        std.json.fmt(&data, .{ .emit_null_optional_fields = false }),
    });

    defer gpa.free(json_string);

    const content = try gpa.alloc(u8, rsa.paddedLength(json_string.len));
    defer gpa.free(content);

    var sign: [rsa.sign_size]u8 = undefined;

    rsa.encrypt(json_string, content);
    rsa.sign(json_string, &sign);

    const signed_response = try std.fmt.allocPrint(gpa, "{f}", .{
        std.json.fmt(&SignedResponse{ .content = content, .sign = &sign }, .{}),
    });

    defer gpa.free(signed_response);
    try req.respond(signed_response, .{});
}

const Params = struct {
    const ParamType = enum { version, seed, rsa_ver };

    const param_name_map: std.StaticStringMap(ParamType) = .initComptime(.{
        .{ "version", .version },
        .{ "seed", .seed },
        .{ "rsa_ver", .rsa_ver },
    });

    version: []const u8,
    seed: []const u8,
    rsa_ver: u32,

    fn extract(query: []const u8) !Params {
        var version: ?[]const u8 = null;
        var seed: ?[]const u8 = null;
        var rsa_ver: ?[]const u8 = null;

        var iter = QueryIterator.iterate(query);

        while (iter.next()) |pair| {
            if (param_name_map.get(pair.key)) |param_type| {
                switch (param_type) {
                    .version => version = pair.value,
                    .seed => seed = pair.value,
                    .rsa_ver => rsa_ver = pair.value,
                }
            }
        }

        return .{
            .version = version orelse return error.MissingVersion,
            .seed = seed orelse return error.MissingSeed,
            .rsa_ver = std.fmt.parseInt(u32, rsa_ver orelse return error.MissingRsaVer, 10) catch return error.InvalidRsaVerNum,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("(version: {s}, seed: {s}, rsa_ver: {})", .{
            self.version,
            self.seed,
            self.rsa_ver,
        });
    }
};

const SignedResponse = struct {
    content: []const u8,
    sign: []const u8,

    pub fn jsonStringify(self: *const @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("content");
        try jws.print("\"{b64}\"", .{self.content});
        try jws.objectField("sign");
        try jws.print("\"{b64}\"", .{self.sign});
        try jws.endObject();
    }
};

const ServerGateway = struct {
    ip: []const u8,
    port: u16,
};

const CdnGameRes = struct {
    base_url: []const u8,
    res_revision: []const u8,
    audio_revision: []const u8,
    branch: []const u8,
    md5_files: []const u8,
};

const CdnDesignData = struct {
    base_url: []const u8,
    data_revision: []const u8,
    md5_files: []const u8,
};

const CdnSilenceData = struct {
    base_url: []const u8,
    silence_revision: []const u8,
    md5_files: []const u8,
};

const CdnConfExt = struct {
    game_res: CdnGameRes,
    design_data: CdnDesignData,
    silence_data: CdnSilenceData,
};

const RegionSwitchFunc = packed struct {
    enable_performance_log: u1,
    enable_operation_log: u1,
    is_kcp: u1,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("enablePerformanceLog");
        try jws.write(self.enable_performance_log);
        try jws.objectField("enableOperationLog");
        try jws.write(self.enable_operation_log);
        try jws.objectField("isKcp");
        try jws.write(self.is_kcp);
        try jws.endObject();
    }
};

const RegionExtension = struct {
    func_switch: RegionSwitchFunc,
};

const ServerDispatchData = struct {
    retcode: i32,
    title: []const u8,
    region_name: []const u8,
    client_secret_key: []const u8,
    cdn_check_url: []const u8,
    gateway: ServerGateway,
    cdn_conf_ext: CdnConfExt,
    region_ext: RegionExtension,
};
