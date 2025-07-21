const std = @import("std");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const scan_dirs = build_options.scan_dirs;
    const output_dir = build_options.output_dir;

    std.log.info("Scanning directories: {s}", .{scan_dirs});
    std.log.info("Output directory: {s}", .{output_dir});

    const actor_files = try discoverMarkedActors(allocator, scan_dirs);
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
        try generateProxy(allocator, actor.path, actor.struct_name, output_dir);
    }
}

const ActorInfo = struct {
    path: []u8,
    struct_name: []const u8,
};

fn discoverMarkedActors(allocator: std.mem.Allocator, scan_dirs: []const []const u8) !std.ArrayList(ActorInfo) {
    var actor_files = std.ArrayList(ActorInfo).init(allocator);

    for (scan_dirs) |dir| {
        scanDirectory(allocator, dir, &actor_files) catch {};
    }

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

fn isBuiltinType(type_name: []const u8) bool {
    const builtin_types = [_][]const u8{
        "u8",             "u16",       "u32",     "u64",      "u128",
        "i8",             "i16",       "i32",     "i64",      "i128",
        "f16",            "f32",       "f64",     "f128",     "bool",
        "void",           "anyerror",  "usize",   "isize",    "comptime_int",
        "comptime_float", "type",      "anytype", "noreturn", "[]const u8",
        "[]u8",           "*const u8", "*u8",
    };

    // Check if it's a basic builtin type
    for (builtin_types) |builtin| {
        if (std.mem.eql(u8, type_name, builtin)) {
            return true;
        }
    }

    // Check for slice types []T or [N]T
    if (std.mem.startsWith(u8, type_name, "[]") or
        std.mem.startsWith(u8, type_name, "["))
    {
        return true;
    }

    // Check for pointer types *T
    if (std.mem.startsWith(u8, type_name, "*")) {
        return true;
    }

    // Check for optional types ?T
    if (std.mem.startsWith(u8, type_name, "?")) {
        return true;
    }

    return false;
}

fn prefixTypeIfNeeded(allocator: std.mem.Allocator, type_name: []const u8, struct_name: []const u8) ![]u8 {
    if (isBuiltinType(type_name)) {
        return try allocator.dupe(u8, type_name);
    }
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ struct_name, type_name });
}

fn generateProxy(allocator: std.mem.Allocator, file_path: []const u8, struct_name: []const u8, output_dir: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    const filename = std.fs.path.basename(file_path);
    const name_without_ext = filename[0 .. filename.len - 4];
    const output_filename = try std.fmt.allocPrint(allocator, "{s}/{s}_proxy.gen.zig", .{ output_dir, name_without_ext });
    defer allocator.free(output_filename);

    std.fs.cwd().makePath(output_dir) catch {};

    const output_file = try std.fs.cwd().createFile(output_filename, .{});
    defer output_file.close();
    const writer = output_file.writer();

    var regular_methods = std.ArrayList(MethodInfo).init(allocator);
    defer regular_methods.deinit();

    var lines = std.mem.splitAny(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "pub fn ")) continue;

        const brace_pos = std.mem.indexOf(u8, trimmed, "{") orelse continue;
        const signature = trimmed[0..brace_pos];
        const method_info = parseMethodSignature(signature) orelse continue;

        if (!std.mem.eql(u8, method_info.name, "init") and !std.mem.eql(u8, method_info.name, "deinit")) {
            try regular_methods.append(method_info);
        }
    }

    try generateActorProxy(allocator, writer, struct_name, regular_methods.items, file_path, output_dir);
}

fn calculateRelativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_file: []const u8) ![]u8 {
    const from_normalized = try std.fs.path.resolve(allocator, &[_][]const u8{from_dir});
    defer allocator.free(from_normalized);

    const to_normalized = try std.fs.path.resolve(allocator, &[_][]const u8{to_file});
    defer allocator.free(to_normalized);

    return std.fs.path.relative(allocator, from_normalized, to_normalized);
}

fn generateActorProxy(allocator: std.mem.Allocator, writer: anytype, struct_name: []const u8, methods: []const MethodInfo, file_path: []const u8, output_dir: []const u8) !void {
    const relative_import = try calculateRelativePath(allocator, output_dir, file_path);
    defer allocator.free(relative_import);

    try writer.print(
        \\const std = @import("std");
        \\const backstage = @import("backstage");
        \\const Context = backstage.Context;
        \\const MethodCall = backstage.MethodCall;
        \\const {s} = @import("{s}").{s};
        \\
        \\pub const {s}Proxy = struct {{
        \\    ctx: *Context,
        \\    allocator: std.mem.Allocator,
        \\    underlying: *{s},
        \\    
        \\    const Self = @This();
        \\
        \\    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {{
        \\        const self = try allocator.create(Self);
        \\        const underlying = try {s}.init(ctx, allocator);
        \\        self.* = .{{
        \\            .ctx = ctx,
        \\            .allocator = allocator,
        \\            .underlying = underlying,
        \\        }};
        \\        return self;
        \\    }}
        \\
        \\    pub fn deinit(self: *Self) !void {{
        \\        try self.underlying.deinit();
        \\        self.allocator.destroy(self);
        \\    }}
        \\
    , .{ struct_name, relative_import, struct_name, struct_name, struct_name, struct_name });

    try generateMethodTable(allocator, writer, methods, struct_name);

    for (methods, 0..) |method, i| {
        try generateProxyMethod(allocator, writer, method, i, struct_name);
    }

    try generateDispatchFunction(writer, methods.len);

    try writer.writeAll("};\n");
}

fn generateMethodTable(allocator: std.mem.Allocator, writer: anytype, methods: []const MethodInfo, struct_name: []const u8) !void {
    try writer.print("    const MethodFn = *const fn (*Self, []const u8) anyerror!void;\n\n", .{});

    for (methods, 0..) |method, i| {
        try generateMethodWrapper(allocator, writer, method, i, struct_name);
    }

    try writer.print("    const method_table = [_]MethodFn{{\n", .{});
    for (methods, 0..) |_, i| {
        try writer.print("        methodWrapper{d},\n", .{i});
    }
    try writer.writeAll("    };\n\n");
}

fn generateMethodWrapper(allocator: std.mem.Allocator, writer: anytype, method: MethodInfo, index: usize, struct_name: []const u8) !void {
    try writer.print("    fn methodWrapper{d}(self: *Self, params_json: []const u8) !void {{\n", .{index});

    const param_names = try extractParamNames(allocator, method.params);
    defer allocator.free(param_names);

    if (param_names.len > 0) {
        try writer.writeAll("        const params = try std.json.parseFromSlice(struct {\n");

        var param_split = std.mem.splitAny(u8, method.params, ",");
        while (param_split.next()) |param| {
            const trimmed = std.mem.trim(u8, param, " \t");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, "self")) |_| continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const param_type = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
                const prefixed_type = try prefixTypeIfNeeded(allocator, param_type, struct_name);
                defer allocator.free(prefixed_type);
                try writer.print("            {s}: {s},\n", .{ param_name, prefixed_type });
            }
        }

        try writer.writeAll("        }, std.heap.page_allocator, params_json, .{});\n");
        try writer.writeAll("        defer params.deinit();\n");

        try writer.print("        try self.underlying.{s}(", .{method.name});
        for (param_names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("params.value.{s}", .{name});
        }
        try writer.writeAll(");\n");
    } else {
        try writer.writeAll("        _ = params_json;\n");
        try writer.print("        try self.underlying.{s}();\n", .{method.name});
    }

    try writer.writeAll("    }\n\n");
}

fn generateProxyMethod(allocator: std.mem.Allocator, writer: anytype, method_info: MethodInfo, method_index: usize, struct_name: []const u8) !void {
    const param_names = try extractParamNames(allocator, method_info.params);
    defer allocator.free(param_names);

    try writer.print("    pub fn {s}(self: *Self", .{method_info.name});

    if (method_info.params.len > 0) {
        var param_split = std.mem.splitAny(u8, method_info.params, ",");
        while (param_split.next()) |param| {
            const trimmed = std.mem.trim(u8, param, " \t");
            if (trimmed.len == 0) continue;
            if (std.mem.indexOf(u8, trimmed, "self")) |_| continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const param_type = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
                const prefixed_type = try prefixTypeIfNeeded(allocator, param_type, struct_name);
                defer allocator.free(prefixed_type);
                try writer.print(", {s}: {s}", .{ param_name, prefixed_type });
            } else {
                try writer.print(", {s}", .{trimmed});
            }
        }
    }

    try writer.writeAll(") !void {\n");

    if (param_names.len > 0) {
        try writer.writeAll("        var params_json = std.ArrayList(u8).init(self.allocator);\n");
        try writer.writeAll("        defer params_json.deinit();\n");
        try writer.writeAll("        try std.json.stringify(.{");

        for (param_names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print(".{s} = {s}", .{ name, name });
        }

        try writer.writeAll("}, .{}, params_json.writer());\n");
        try writer.writeAll("        const params_str = try params_json.toOwnedSlice();\n");
        try writer.writeAll("        defer self.allocator.free(params_str);\n");
    } else {
        try writer.writeAll("        const params_str = \"\";\n");
    }

    try writer.print(
        \\        const method_call = MethodCall{{
        \\            .method_id = {d},
        \\            .params = params_str,
        \\        }};
        \\        try self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);
        \\    }}
        \\
        \\
    , .{method_index});
}

fn generateDispatchFunction(writer: anytype, method_count: usize) !void {
    try writer.print(
        \\    pub fn dispatchMethod(self: *Self, method_call: MethodCall) !void {{
        \\        if (method_call.method_id >= {d}) {{
        \\            return error.UnknownMethod;
        \\        }}
        \\        try method_table[method_call.method_id](self, method_call.params);
        \\    }}
        \\
    , .{method_count});
}
