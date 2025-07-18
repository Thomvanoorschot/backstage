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

    const zignite_dep = b.lazyDependency("zignite", .{ .target = target, .optimize = optimize });
    if (zignite_dep) |zd| {
        backstage_mod.addImport("zignite", zd.module("zignite"));
    }

    if (b.lazyDependency("protobuf", .{ .target = target, .optimize = optimize })) |protobuf_dep| {
        backstage_mod.addImport("protobuf", protobuf_dep.module("protobuf"));

        if (enable_inspector) {
            const gen_proto = b.step("gen-proto", "generates zig files from protocol buffer definitions");
            const protobuf = @import("protobuf");
            const protoc_step = protobuf.RunProtocStep.create(b, protobuf_dep.builder, target, .{
                .destination_directory = b.path("src/inspector"),
                .source_files = &.{
                    "proto/inspector_state.proto",
                },
                .include_directories = &.{"proto"},
            });

            gen_proto.dependOn(&protoc_step.step);
            b.getInstallStep().dependOn(gen_proto);

            const inspector_exe = b.addExecutable(.{
                .name = "inspector",
                .root_source_file = b.path("src/inspector/window.zig"),
                .target = target,
                .optimize = optimize,
            });
            if (zignite_dep) |zd| {
                inspector_exe.root_module.addImport("zignite", zd.module("zignite"));
            }
            inspector_exe.root_module.addImport("protobuf", protobuf_dep.module("protobuf"));

            const install_inspector = b.addInstallArtifact(inspector_exe, .{});
            b.getInstallStep().dependOn(&install_inspector.step);
        }
    }
}

const LibOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
};
