const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_inspector = b.option(bool, "enable_inspector", "Enable inspector window") orelse false;

    const backstage_mod = b.addModule("backstage", .{
        .root_source_file = b.path("src/root.zig"),
    });
    const options = b.addOptions();
    options.addOption(bool, "enable_inspector", enable_inspector);
    backstage_mod.addImport("build_options", options.createModule());

    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    backstage_mod.addImport("xev", xev.module("xev"));
}

const LibOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
};
