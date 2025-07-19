const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const actor_files = try discoverMarkedActors(allocator);
    defer {
        for (actor_files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.struct_name);
        }
        actor_files.deinit();
    }

    if (actor_files.items.len == 0) {
        std.debug.print("No marked actors found. Add '// @generate-proxy' above your actor structs.\n", .{});
        return;
    }

    for (actor_files.items) |actor| {
        try generateProxy(allocator, actor.path, actor.struct_name);
    }
}

const ActorInfo = struct {
    path: []u8,
    struct_name: []const u8,
};

fn discoverMarkedActors(allocator: std.mem.Allocator) !std.ArrayList(ActorInfo) {
    var actor_files = std.ArrayList(ActorInfo).init(allocator);

    scanDirectory(allocator, "examples/src", &actor_files) catch {};
    scanDirectory(allocator, "src", &actor_files) catch {};

    return actor_files;
}

fn scanDirectory(allocator: std.mem.Allocator, dir_path: []const u8, actor_files: *std.ArrayList(ActorInfo)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(file_path);

        if (findMarkedActors(allocator, file_path)) |actors| {
            if (actors == null) {
                continue;
            }
            defer actors.?.deinit();
            for (actors.?.items) |struct_name| {
                const actor_info = ActorInfo{
                    .path = try allocator.dupe(u8, file_path),
                    .struct_name = struct_name,
                };
                try actor_files.append(actor_info);
            }
        } else |_| {}
    }
}

fn findMarkedActors(allocator: std.mem.Allocator, file_path: []const u8) !?std.ArrayList([]const u8) {
    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch return null;
    defer allocator.free(content);

    var actors = std.ArrayList([]const u8).init(allocator);
    var lines = std.mem.splitAny(u8, content, "\n");
    var next_struct_is_actor = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "// @generate-proxy")) {
            next_struct_is_actor = true;
            continue;
        }

        if (next_struct_is_actor) {
            if (std.mem.indexOf(u8, trimmed, "= struct {")) |_| {
                if (std.mem.indexOf(u8, trimmed, "const ")) |const_pos| {
                    const after_const = trimmed[const_pos + 6 ..];
                    if (std.mem.indexOf(u8, after_const, " =")) |eq_pos| {
                        const struct_name = std.mem.trim(u8, after_const[0..eq_pos], " \t");
                        try actors.append(try allocator.dupe(u8, struct_name));
                    }
                }
                next_struct_is_actor = false;
            } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//")) {
                next_struct_is_actor = false;
            }
        }
    }

    if (actors.items.len == 0) {
        actors.deinit();
        return null;
    }

    return actors;
}

fn generateProxy(allocator: std.mem.Allocator, file_path: []const u8, struct_name: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    const output_filename = try std.fmt.allocPrint(allocator, "{s}Proxy.zig", .{struct_name});
    defer allocator.free(output_filename);

    const output_file = try std.fs.cwd().createFile(output_filename, .{});
    defer output_file.close();

    const writer = output_file.writer();

    try writer.print(
        \\// AUTO-GENERATED ACTOR PROXY. DO NOT EDIT BY HAND.
        \\// Generated proxy for {s}
        \\
        \\const std = @import("std");
        \\const backstage = @import("backstage");
        \\const Context = backstage.Context;
        \\const Envelope = backstage.Envelope;
        \\
        \\pub const {s}Proxy = struct {{
        \\    const Self = @This();
        \\    
        \\    ctx: *Context,
        \\    allocator: std.mem.Allocator,
        \\
    , .{ struct_name, struct_name });

    var lines = std.mem.splitAny(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            if (std.mem.indexOf(u8, trimmed, "{")) |brace_pos| {
                const signature = trimmed[0..brace_pos];
                try writer.print("    {s}{{\n", .{signature});
                try suppressParameters(writer, signature);
                try writer.writeAll("        // TODO: implement\n    }\n\n");
            }
        }
    }

    try writer.writeAll("};\n");
    std.debug.print("Generated: {s}\n", .{output_filename});
}

fn suppressParameters(writer: anytype, signature: []const u8) !void {
    const paren_start = std.mem.indexOf(u8, signature, "(") orelse return;
    const paren_end = std.mem.lastIndexOf(u8, signature, ")") orelse return;

    if (paren_end <= paren_start + 1) return;

    const params = signature[paren_start + 1 .. paren_end];
    var param_split = std.mem.splitAny(u8, params, ",");

    while (param_split.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            if (!std.mem.eql(u8, param_name, "_")) {
                try writer.print("        _ = {s};\n", .{param_name});
            }
        }
    }
}
