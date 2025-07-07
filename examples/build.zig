const std = @import("std");
const Build = std.Build;
const zignite_pkg = @import("zignite");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backstage_dep = b.dependency("backstage", .{
        .target = target,
        .optimize = optimize,
    });

    const example_names = .{
        "hello_world",
    };

    inline for (example_names) |example_name| {
        const example = b.addTest(.{
            .root_source_file = b.path(example_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .name = example_name,
        });
        example.root_module.addImport("backstage", backstage_dep.module("backstage"));
        b.installArtifact(example);

        const run = b.addRunArtifact(example);
        b.step(example_name, "Run " ++ example_name).dependOn(&run.step);
    }
}
