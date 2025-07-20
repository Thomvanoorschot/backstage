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

        if (try findMarkedActors(allocator, file_path)) |actors| {
            defer actors.deinit();
            for (actors.items) |struct_name| {
                try actor_files.append(.{
                    .path = try allocator.dupe(u8, file_path),
                    .struct_name = struct_name,
                });
            }
        }
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
                if (extractStructName(trimmed)) |name| {
                    try actors.append(try allocator.dupe(u8, name));
                }
                next_struct_is_actor = false;
            } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//")) {
                next_struct_is_actor = false;
            }
        }
    }

    return if (actors.items.len == 0) null else actors;
}

fn extractStructName(line: []const u8) ?[]const u8 {
    const const_pos = std.mem.indexOf(u8, line, "const ") orelse return null;
    const after_const = line[const_pos + 6 ..];
    const eq_pos = std.mem.indexOf(u8, after_const, " =") orelse return null;
    return std.mem.trim(u8, after_const[0..eq_pos], " \t");
}

const MethodInfo = struct {
    name: []const u8,
    params: []const u8,
    has_return: bool,
};

fn parseMethodSignature(signature: []const u8) ?MethodInfo {
    const fn_start = std.mem.indexOf(u8, signature, "pub fn ") orelse return null;
    const name_start = fn_start + 7;
    const paren_pos = std.mem.indexOf(u8, signature[name_start..], "(") orelse return null;
    const method_name = std.mem.trim(u8, signature[name_start .. name_start + paren_pos], " \t");

    const paren_start = std.mem.indexOf(u8, signature, "(") orelse return null;
    const paren_end = std.mem.lastIndexOf(u8, signature, ")") orelse return null;

    const params = if (paren_end > paren_start + 1) signature[paren_start + 1 .. paren_end] else "";
    const has_return = std.mem.indexOf(u8, signature, "!") != null or
        std.mem.indexOf(u8, signature[paren_end..], ") ") != null;

    return MethodInfo{
        .name = method_name,
        .params = params,
        .has_return = has_return,
    };
}

fn extractParamNames(allocator: std.mem.Allocator, params: []const u8) ![][]const u8 {
    if (params.len == 0) return &[_][]const u8{};

    var param_names = std.ArrayList([]const u8).init(allocator);
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

    return param_names.toOwnedSlice();
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

    // Write header
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

    // Generate methods
    var lines = std.mem.splitAny(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub fn ")) continue;

        const brace_pos = std.mem.indexOf(u8, trimmed, "{") orelse continue;
        const signature = trimmed[0..brace_pos];
        const method_info = parseMethodSignature(signature) orelse continue;

        if (std.mem.eql(u8, method_info.name, "init")) {
            try generateInitMethod(allocator, writer, signature, struct_name, method_info.params);
        } else if (std.mem.eql(u8, method_info.name, "deinit")) {
            try generateDeinitMethod(writer, signature);
        } else {
            try generateRegularMethod(allocator, writer, signature, method_info);
        }
    }

    try writer.writeAll("};\n");
    std.debug.print("Generated: {s}\n", .{output_filename});
}

fn generateInitMethod(allocator: std.mem.Allocator, writer: anytype, signature: []const u8, struct_name: []const u8, params: []const u8) !void {
    try writer.print("    {s}{{\n", .{signature});

    const param_names = try extractParamNames(allocator, params);
    defer allocator.free(param_names);

    try writer.print("        return Self{{ .underlying = {s}.init(", .{struct_name});
    for (param_names, 0..) |name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}", .{name});
    }
    try writer.writeAll(") };\n    }\n\n");
}

fn generateDeinitMethod(writer: anytype, signature: []const u8) !void {
    if (std.mem.indexOf(u8, signature, "_:")) |pos| {
        const before_param = signature[0..pos];
        const after_colon = signature[pos + 1 ..];
        try writer.print("    {s}self{s}{{\n", .{ before_param, after_colon });
    } else {
        try writer.print("    {s}{{\n", .{signature});
    }
    try writer.writeAll("        self.underlying.deinit();\n    }\n\n");
}

fn generateRegularMethod(allocator: std.mem.Allocator, writer: anytype, signature: []const u8, method_info: MethodInfo) !void {
    try writer.print("    {s}{{\n", .{signature});

    const param_names = try extractParamNames(allocator, method_info.params);
    defer allocator.free(param_names);

    const return_prefix = if (method_info.has_return) "return " else "";
    try writer.print("        {s}self.underlying.{s}(", .{ return_prefix, method_info.name });

    for (param_names, 0..) |name, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}", .{name});
    }
    try writer.writeAll(");\n    }\n\n");
}
