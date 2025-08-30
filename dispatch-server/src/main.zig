const std = @import("std");
const common = @import("common");
const log = std.log;

const Config = @import("Config.zig");

const http = @import("http.zig");
const query_dispatch = @import("query_dispatch.zig");
const query_gateway = @import("query_gateway.zig");

const Allocator = std.mem.Allocator;
const Rsa = common.crypto.Rsa;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const std_options: std.Options = .{
    // keep debug logs even in release builds for now
    .log_level = .debug,
};

const req_handler_map: http.ReqHandlerMap = .initComptime(.{
    .{ "/query_dispatch", @import("query_dispatch.zig").handle },
    .{ "/query_gateway", @import("query_gateway.zig").handle },
});

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    _ = try std.fs.File.stdout().write(
        \\    __  ___     ____               _ _____  _____
        \\    \ \/ (_)___/ / /_  ____ ______(_)__  / / ___/
        \\     \  / / __  / __ \/ __ `/ ___/ /  / /  \__ \ 
        \\     / / / /_/ / / / / /_/ / /  / /  / /_____/ / 
        \\    /_/_/\__,_/_/ /_/\__,_/_/  /_/  /____/____/  
        \\
        \\
    );

    const config = try common.config_util.loadOrCreateConfig(Config, "dispatch_config.zon", gpa);
    defer common.config_util.freeConfig(gpa, config);

    const address = try std.net.Address.parseIp4(config.http_addr, config.http_port);
    try http.serve(gpa, address, &config, &req_handler_map);
}
