const std = @import("std");
const common = @import("common");

const gateway = @import("net/gateway.zig");
const Config = @import("Config.zig");
const Globals = @import("Globals.zig");
const TemplateCollection = @import("data/templates.zig").TemplateCollection;

const EventGraphTemplateMap = @import("data/graph/EventGraphTemplateMap.zig");
const graph_loader = @import("data/graph/graph_loader.zig");

pub const std_options: std.Options = .{
    // keep debug logs even in release builds for now
    .log_level = .debug,
};

pub fn main() !void {
    // TODO: use SmpAllocator for release builds.
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(debug_allocator.deinit() == .ok);
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

    const allocator = debug_allocator.allocator();

    const config = try common.config_util.loadOrCreateConfig(Config, "gameserver_config.zon", gpa);
    defer common.config_util.freeConfig(gpa, config);

    const gameplay_settings = try common.config_util.loadOrCreateConfig(Globals.GameplaySettings, "gameplay_settings.zon", gpa);
    defer common.config_util.freeConfig(gpa, gameplay_settings);

    var templates = try TemplateCollection.load(allocator);
    defer templates.deinit();

    var event_graph_map = try graph_loader.loadTemplateMap(allocator);
    defer event_graph_map.deinit();

    const globals = Globals{
        .templates = templates,
        .event_graph_map = event_graph_map,
        .gameplay_settings = gameplay_settings,
    };

    const address = try std.net.Address.parseIp4(config.udp_addr, config.udp_port);
    gateway.listen(allocator, address, config.shutdown_on_disconnect, &globals) catch |err| {
        std.log.err("failed to initialize gateway: {}", .{err});
        return err;
    };
}
