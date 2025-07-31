const std = @import("std");
const Build = std.Build;
const zignite_pkg = @import("zignite");

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const backstage_dep = b.dependency("backstage", .{
        .target = target,
        .optimize = optimize,
        .generate_proxies = true,
    });

    const example_names = .{
        "hello_world_string",
        "hello_world_struct",
        "large_struct",
        "multiple_methods",
        "actor_to_actor",
        "discared_variable",
        "imported_variable",
        "multiple_messages",
        "poison_pill",
        "pub_sub",
    };

    const generator = backstage_dep.artifact("generator");
    b.installArtifact(generator);
    const run_generator = b.addRunArtifact(generator);
    // Output directory
    run_generator.addArg("src/generated");
    // Scan directories
    run_generator.addArg("src");
    // You can add more scan directories here
    //run_generator.addArg("other_directory");

    const gen_proxies = b.step("gen-proxies", "Generate actor proxies");
    gen_proxies.dependOn(&run_generator.step);
    b.getInstallStep().dependOn(gen_proxies);

    const test_step = b.step("test", "Run all tests");

    inline for (example_names) |example_name| {
        const example = b.addTest(.{
            .root_source_file = b.path("src/" ++ example_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .name = example_name,
        });
        example.root_module.addImport("backstage", backstage_dep.module("backstage"));

        const run = b.addRunArtifact(example);
        const test_install = b.addInstallArtifact(
            example,
            .{
                .dest_dir = .{
                    .override = .{
                        .custom = "tests",
                    },
                },
                .dest_sub_path = example_name,
            },
        );
        var run_step = b.step(example_name, "Run " ++ example_name);
        run_step.dependOn(&run.step);
        run_step.dependOn(&test_install.step);
        test_step.dependOn(run_step);
    }
}
