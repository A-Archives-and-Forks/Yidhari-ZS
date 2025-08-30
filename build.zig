const protobuf = @import("protobuf_nap");
const std = @import("std");
const builtin = @import("builtin");

const common_module_name = "common";
const protocol_module_name = "protocol";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const opts = .{ .target = target, .optimize = optimize };

    const protobuf_dep = b.dependency("protobuf_nap", opts);

    // in order to run protoc on host machine, host target should be passed to compile protoc-gen-zig
    const host_target: std.Build.ResolvedTarget = .{
        .query = .fromTarget(&builtin.target),
        .result = builtin.target,
    };

    const common = b.createModule(.{
        .root_source_file = b.path("common/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const protocol = b.createModule(.{
        .root_source_file = b.path("protocol/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protobuf", .module = protobuf_dep.module("protobuf") }},
    });

    const dispatch = b.addExecutable(.{
        .name = "yidhari-dispatch-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("dispatch-server/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = common_module_name, .module = common }},
        }),
    });

    const protoc_step: ?*std.Build.Step = blk: {
        if (std.fs.cwd().access("protocol/proto/nap.proto", .{})) {
            const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, host_target, .{
                .destination_directory = b.path("protocol/src"),
                .source_files = &.{
                    "protocol/proto/nap.proto",
                    "protocol/proto/action.proto",
                    "protocol/proto/head.proto",
                },
                .include_directories = &.{},
            });

            b.getInstallStep().dependOn(&protoc_step.step);
            break :blk &protoc_step.step;
        } else |_| {
            // don't invoke protoc if proto definition doesn't exist
            break :blk null;
        }
    };

    const game_server = b.addExecutable(.{
        .name = "yidhari-game-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("game-server/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = common_module_name, .module = common },
                .{ .name = protocol_module_name, .module = protocol },
            },
        }),
    });

    if (protoc_step) |step| game_server.step.dependOn(step);

    addCommonAssets(b, common);
    addFilecfgAssets(b, game_server.root_module);

    dispatch.root_module.addAnonymousImport(
        "dispatch_config.default.zon",
        .{ .root_source_file = b.path("dispatch-server/dispatch_config.default.zon") },
    );

    game_server.root_module.addAnonymousImport(
        "gameserver_config.default.zon",
        .{ .root_source_file = b.path("game-server/gameserver_config.default.zon") },
    );

    game_server.root_module.addAnonymousImport(
        "gameplay_settings.default.zon",
        .{ .root_source_file = b.path("game-server/gameplay_settings.default.zon") },
    );

    game_server.root_module.addAnonymousImport(
        "initial_xorpad.bin",
        .{ .root_source_file = b.path("assets/security/initial_xorpad.bin") },
    );

    b.step("build-yidhari-dispatch", "Build the dispatch-server").dependOn(&b.addInstallArtifact(dispatch, .{}).step);
    b.step("build-yidhari-gameserver", "Build the game-server").dependOn(&b.addInstallArtifact(game_server, .{}).step);

    b.step("run-yidhari-dispatch", "Build and run the dispatch-server.").dependOn(&b.addRunArtifact(dispatch).step);
    b.step("run-yidhari-gameserver", "Build and run the game-server.").dependOn(&b.addRunArtifact(game_server).step);
}

fn addCommonAssets(b: *std.Build, module: *std.Build.Module) void {
    const common_assets = &.{
        .{ "client_public_key.der", "assets/security/client_public_key.der" },
        .{ "server_private_key.der", "assets/security/server_private_key.der" },
    };

    inline for (common_assets) |asset| {
        const alias, const path = asset;
        module.addAnonymousImport(alias, .{ .root_source_file = b.path(path) });
    }
}

fn addFilecfgAssets(b: *std.Build, module: *std.Build.Module) void {
    const filecfg_dir = std.fs.cwd().openDir("assets/Filecfg/", .{ .iterate = true }) catch @panic("assets/Filecfg directory doesn't exist");
    var walker = filecfg_dir.walk(b.allocator) catch @panic("Out of Memory");
    defer walker.deinit();

    while (true) {
        const entry = walker.next() catch break orelse break;
        if (entry.kind == .file) {
            const path = std.mem.concat(b.allocator, u8, &.{ "assets/Filecfg/", entry.path }) catch @panic("Out of Memory");

            module.addAnonymousImport(entry.path, .{
                .root_source_file = b.path(path),
            });
        }
    }
}
