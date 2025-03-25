const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backstage_mod = b.addModule("backstage", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const xev = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const backstage_lib = try buildLibbackstage(b, .{
        .target = target,
        .optimize = optimize,
    });
    backstage_mod.addImport("xev", xev.module("xev"));
    
    backstage_mod.linkLibrary(backstage_lib);

    const examples = .{
        "example",
    };

    inline for (examples) |example| {
        buildExample(b, example, .{
            .target = target,
            .optimize = optimize,
            .backstage_mod = backstage_mod,
        });
    }
}

const LibOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
};
fn buildLibbackstage(b: *std.Build, options: LibOptions) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "backstage",
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    lib.addIncludePath(b.path("lib/neco"));
    lib.installHeadersDirectory(b.path("lib/neco"), "neco", .{});


    b.installArtifact(lib);

    const necoCFlags = &.{
        "-std=c11",
        "-O0",
        "-g3",
        "-Wall",
        "-Wextra",
        "-fstrict-aliasing",
        "-DLLCO_NOUNWIND",
        "-pedantic",
        "-Werror",
        "-fno-omit-frame-pointer",
    };

    lib.addIncludePath(b.path("lib/neco"));
    lib.addCSourceFile(.{
        .file = b.path("lib/neco/neco.c"),
        .flags = necoCFlags,
    });

    return lib;
}

const ExampleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    backstage_mod: *std.Build.Module,
};
fn buildExample(b: *std.Build, comptime exampleName: []const u8, options: ExampleOptions) void {
    const exe = b.addExecutable(.{
        .name = "backstage-" ++ exampleName,
        .root_source_file = .{ .cwd_relative = "src/examples/" ++ exampleName ++ ".zig" },
        .target = options.target,
        .optimize = options.optimize,
    });
    const websocket_dep = b.dependency("websocket", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    exe.root_module.addImport("backstage", options.backstage_mod);
    exe.root_module.addImport("websocket", websocket_dep.module("websocket"));
    exe.linkSystemLibrary("c");

    const necoCFlags = &.{
        "-std=c11",
        "-O0",
        "-g3",
        "-Wall",
        "-Wextra",
        "-fstrict-aliasing",
        "-DLLCO_NOUNWIND",
        "-pedantic",
        "-Werror",
        "-fno-omit-frame-pointer",
    };

    options.backstage_mod.addIncludePath(b.path("lib/neco"));
    exe.addCSourceFile(.{
        .file = b.path("lib/neco/neco.c"),
        .flags = necoCFlags,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    b.step("run-" ++ exampleName, "Run example " ++ exampleName).dependOn(&run_cmd.step);
}
