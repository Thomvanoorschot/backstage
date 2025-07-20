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

    const filename = std.fs.path.basename(file_path);
    const name_without_ext = filename[0 .. filename.len - 4];
    const output_filename = try std.fmt.allocPrint(allocator, "{s}_proxy.gen.zig", .{name_without_ext});
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
        \\const {s} = @import("{s}").{s};
        \\
        \\pub const {s}Proxy = struct {{
        \\    ctx: *Context,
        \\    allocator: std.mem.Allocator,
        \\    underlying: {s},
        \\    
        \\    const Self = @This();
        \\
    , .{ struct_name, struct_name, filename, struct_name, struct_name, struct_name });

    var lines = std.mem.splitAny(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        // Creating method proxies
        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            if (std.mem.indexOf(u8, trimmed, "{")) |brace_pos| {
                const signature = trimmed[0..brace_pos];

                // Extract method name to check if we should exclude it
                const fn_start = std.mem.indexOf(u8, signature, "pub fn ") orelse continue;
                const name_start = fn_start + 7; // length of "pub fn "
                const paren_pos = std.mem.indexOf(u8, signature[name_start..], "(") orelse continue;
                const method_name = std.mem.trim(u8, signature[name_start .. name_start + paren_pos], " \t");

                // Handle init and deinit functions specially
                if (std.mem.eql(u8, method_name, "init")) {
                    try writer.print("    {s}{{\n", .{signature});
                    try generateInitMethod(writer, signature, struct_name);
                    try writer.writeAll("    }\n\n");
                    continue;
                } else if (std.mem.eql(u8, method_name, "deinit")) {
                    // Generate deinit with corrected signature (always use 'self')
                    const corrected_signature = try correctDeinitSignature(allocator, signature);
                    defer allocator.free(corrected_signature);
                    try writer.print("    {s}{{\n", .{corrected_signature});
                    try writer.writeAll("        self.underlying.deinit();\n");
                    try writer.writeAll("    }\n\n");
                    continue;
                }

                try writer.print("    {s}{{\n", .{signature});
                try generateMethodCall(writer, signature);
                try writer.writeAll("    }\n\n");
            }
        }
    }

    try writer.writeAll("};\n");
    std.debug.print("Generated: {s}\n", .{output_filename});
}

fn generateMethodCall(writer: anytype, signature: []const u8) !void {
    // Extract method name
    const fn_start = std.mem.indexOf(u8, signature, "pub fn ") orelse return;
    const name_start = fn_start + 7; // length of "pub fn "
    const paren_pos = std.mem.indexOf(u8, signature[name_start..], "(") orelse return;
    const method_name = std.mem.trim(u8, signature[name_start .. name_start + paren_pos], " \t");

    // Extract parameters
    const paren_start = std.mem.indexOf(u8, signature, "(") orelse return;
    const paren_end = std.mem.lastIndexOf(u8, signature, ")") orelse return;

    // Check if method has a return type
    const has_return = std.mem.indexOf(u8, signature, "!") != null or
        (std.mem.lastIndexOf(u8, signature, ")") != null and
            std.mem.indexOf(u8, signature[paren_end..], ") ") != null);

    if (paren_end <= paren_start + 1) {
        // No parameters
        if (has_return) {
            try writer.print("        return self.underlying.{s}();\n", .{method_name});
        } else {
            try writer.print("        self.underlying.{s}();\n", .{method_name});
        }
        return;
    }

    // Extract parameter names
    const params = signature[paren_start + 1 .. paren_end];
    var param_names = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer param_names.deinit();

    var param_split = std.mem.splitAny(u8, params, ",");
    while (param_split.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            if (!std.mem.eql(u8, param_name, "self")) {
                try param_names.append(param_name);
            }
        }
    }

    // Generate method call
    if (has_return) {
        try writer.print("        return self.underlying.{s}(", .{method_name});
    } else {
        try writer.print("        self.underlying.{s}(", .{method_name});
    }

    for (param_names.items, 0..) |param_name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}", .{param_name});
    }

    try writer.writeAll(");\n");
}

fn generateInitMethod(writer: anytype, signature: []const u8, struct_name: []const u8) !void {
    // Extract parameters
    const paren_start = std.mem.indexOf(u8, signature, "(") orelse return;
    const paren_end = std.mem.lastIndexOf(u8, signature, ")") orelse return;

    if (paren_end <= paren_start + 1) {
        // No parameters
        try writer.print("        return Self{{ .underlying = {s}.init() }};\n", .{struct_name});
        return;
    }

    // Extract parameter names (excluding self if it's a method)
    const params = signature[paren_start + 1 .. paren_end];
    var param_names = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer param_names.deinit();

    var param_split = std.mem.splitAny(u8, params, ",");
    while (param_split.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            if (!std.mem.eql(u8, param_name, "self")) {
                try param_names.append(param_name);
            }
        }
    }

    // Generate init call
    try writer.print("        return Self{{ .underlying = {s}.init(", .{struct_name});

    for (param_names.items, 0..) |param_name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}", .{param_name});
    }

    try writer.writeAll(") };\n");
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

fn correctDeinitSignature(allocator: std.mem.Allocator, signature: []const u8) ![]u8 {
    // Find the parameter part
    const paren_start = std.mem.indexOf(u8, signature, "(") orelse return try allocator.dupe(u8, signature);
    const paren_end = std.mem.lastIndexOf(u8, signature, ")") orelse return try allocator.dupe(u8, signature);

    if (paren_end <= paren_start + 1) {
        // No parameters, return as-is
        return try allocator.dupe(u8, signature);
    }

    const params = signature[paren_start + 1 .. paren_end];

    // Find the first parameter and replace its name with 'self'
    if (std.mem.indexOf(u8, params, ":")) |colon_pos| {
        const param_type = std.mem.trim(u8, params[colon_pos..], " \t");

        // Reconstruct signature with 'self' as parameter name
        return try std.fmt.allocPrint(allocator, "{s}(self{s}){s}", .{
            signature[0..paren_start],
            param_type,
            signature[paren_end + 1 ..], // Skip the closing parenthesis
        });
    }

    return try allocator.dupe(u8, signature);
}
