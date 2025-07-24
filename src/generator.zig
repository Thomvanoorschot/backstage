const std = @import("std");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const scan_dirs = build_options.scan_dirs;
    const output_dir = build_options.output_dir;

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
    var unused_count: u32 = 1;
    var param_index: u32 = 0;

    while (param_split.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            if (param_index == 0) {
                param_index += 1;
                continue;
            }

            const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            if (std.mem.eql(u8, param_name, "_")) {
                const display_name = try std.fmt.allocPrint(allocator, "unused_param{d}", .{unused_count});
                try param_names.append(display_name);
                unused_count += 1;
            } else {
                try param_names.append(param_name);
            }
            param_index += 1;
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

    for (builtin_types) |builtin| {
        if (std.mem.eql(u8, type_name, builtin)) {
            return true;
        }
    }

    if (std.mem.startsWith(u8, type_name, "[]") or
        std.mem.startsWith(u8, type_name, "["))
    {
        return true;
    }

    if (std.mem.startsWith(u8, type_name, "*")) {
        return true;
    }

    if (std.mem.startsWith(u8, type_name, "?")) {
        return true;
    }

    return false;
}

fn isTypeDefinedInFile(file_content: []const u8, type_name: []const u8) bool {
    var lines = std.mem.splitAny(u8, file_content, "\n");

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "pub const ") or std.mem.startsWith(u8, trimmed, "const ")) {
            if (extractConstName(trimmed)) |name| {
                if (std.mem.eql(u8, name, type_name)) {
                    if (std.mem.indexOf(u8, trimmed, "= struct")) |_| {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

fn resolveTypeWithImports(allocator: std.mem.Allocator, type_name: []const u8, file_content: []const u8, struct_name: []const u8) ![]u8 {
    if (isBuiltinType(type_name)) {
        return try allocator.dupe(u8, type_name);
    }

    if (std.mem.startsWith(u8, type_name, "*") or
        std.mem.startsWith(u8, type_name, "[]") or
        std.mem.startsWith(u8, type_name, "?"))
    {
        var inner_start: usize = 0;
        if (std.mem.startsWith(u8, type_name, "*")) inner_start = 1;
        if (std.mem.startsWith(u8, type_name, "[]")) inner_start = 2;
        if (std.mem.startsWith(u8, type_name, "?")) inner_start = 1;

        const inner_type = type_name[inner_start..];
        const resolved_inner = try resolveTypeWithImports(allocator, inner_type, file_content, struct_name);
        defer allocator.free(resolved_inner);

        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ type_name[0..inner_start], resolved_inner });
    }

    const type_root = if (std.mem.indexOf(u8, type_name, ".")) |dot_pos|
        type_name[0..dot_pos]
    else
        type_name;

    if (findConstDefinition(file_content, type_root)) |_| {
        return try allocator.dupe(u8, type_name);
    }

    if (isTypeDefinedInStruct(file_content, struct_name, type_name)) {
        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ struct_name, type_name });
    }

    return try allocator.dupe(u8, type_name);
}

fn findConstDefinition(file_content: []const u8, const_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitAny(u8, file_content, "\n");

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "const ")) {
            if (extractConstName(trimmed)) |name| {
                if (std.mem.eql(u8, name, const_name)) {
                    return trimmed;
                }
            }
        }
    }

    return null;
}

fn isTypeDefinedInStruct(file_content: []const u8, struct_name: []const u8, type_name: []const u8) bool {
    var lines = std.mem.splitAny(u8, file_content, "\n");
    var inside_target_struct = false;
    var brace_depth: i32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (!inside_target_struct) {
            if (std.mem.indexOf(u8, trimmed, "= struct {")) |_| {
                if (extractStructName(trimmed)) |name| {
                    if (std.mem.eql(u8, name, struct_name)) {
                        inside_target_struct = true;
                        brace_depth = 1;
                        continue;
                    }
                }
            }
            continue;
        }

        for (trimmed) |char| {
            if (char == '{') brace_depth += 1;
            if (char == '}') brace_depth -= 1;
        }

        if (brace_depth == 0) {
            break;
        }

        if (std.mem.startsWith(u8, trimmed, "pub const ") or std.mem.startsWith(u8, trimmed, "const ")) {
            if (extractConstName(trimmed)) |name| {
                if (std.mem.eql(u8, name, type_name)) {
                    return true;
                }
            }
        }
    }

    return false;
}

fn extractConstName(line: []const u8) ?[]const u8 {
    const const_pos = std.mem.indexOf(u8, line, "const ") orelse return null;
    const after_const = line[const_pos + 6 ..];
    const eq_pos = std.mem.indexOf(u8, after_const, " =") orelse return null;
    return std.mem.trim(u8, after_const[0..eq_pos], " \t");
}

fn collectTypesToImport(allocator: std.mem.Allocator, params: []const u8, file_content: []const u8, struct_name: []const u8, types_to_import: *std.StringHashMap(void)) !void {
    var param_split = std.mem.splitAny(u8, params, ",");
    while (param_split.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOf(u8, trimmed, "self")) |_| continue;

        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const param_type = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
            try collectTypeFromTypeString(allocator, param_type, file_content, struct_name, types_to_import);
        }
    }
}

fn collectTypeFromTypeString(allocator: std.mem.Allocator, type_name: []const u8, file_content: []const u8, struct_name: []const u8, types_to_import: *std.StringHashMap(void)) !void {
    var actual_type = type_name;
    if (std.mem.startsWith(u8, type_name, "*")) {
        actual_type = type_name[1..];
    } else if (std.mem.startsWith(u8, type_name, "[]")) {
        actual_type = type_name[2..];
    } else if (std.mem.startsWith(u8, type_name, "?")) {
        actual_type = type_name[1..];
    }

    if (isBuiltinType(actual_type)) {
        return;
    }

    const type_root = if (std.mem.indexOf(u8, actual_type, ".")) |dot_pos|
        actual_type[0..dot_pos]
    else
        actual_type;

    if (findConstDefinition(file_content, type_root)) |_| {
        return;
    }

    if (isTypeDefinedInFile(file_content, actual_type) or isTypeDefinedInStruct(file_content, struct_name, actual_type)) {
        if (!types_to_import.contains(actual_type)) {
            const owned_type = try allocator.dupe(u8, actual_type);
            try types_to_import.put(owned_type, {});
        }
    }
}

fn resolveTypeForProxy(allocator: std.mem.Allocator, type_name: []const u8, file_content: []const u8, struct_name: []const u8, types_to_import: *std.StringHashMap(void)) ![]u8 {
    if (isBuiltinType(type_name)) {
        return try allocator.dupe(u8, type_name);
    }

    if (std.mem.startsWith(u8, type_name, "*") or
        std.mem.startsWith(u8, type_name, "[]") or
        std.mem.startsWith(u8, type_name, "?"))
    {
        var inner_start: usize = 0;
        if (std.mem.startsWith(u8, type_name, "*")) inner_start = 1;
        if (std.mem.startsWith(u8, type_name, "[]")) inner_start = 2;
        if (std.mem.startsWith(u8, type_name, "?")) inner_start = 1;

        const inner_type = type_name[inner_start..];
        const resolved_inner = try resolveTypeForProxy(allocator, inner_type, file_content, struct_name, types_to_import);
        defer allocator.free(resolved_inner);

        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ type_name[0..inner_start], resolved_inner });
    }

    const type_root = if (std.mem.indexOf(u8, type_name, ".")) |dot_pos|
        type_name[0..dot_pos]
    else
        type_name;

    if (findConstDefinition(file_content, type_root)) |_| {
        return try allocator.dupe(u8, type_name);
    }

    if (types_to_import.contains(type_name)) {
        return try allocator.dupe(u8, type_name);
    }

    return try allocator.dupe(u8, type_name);
}

fn structNameToSnakeCase(allocator: std.mem.Allocator, struct_name: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    for (struct_name, 0..) |char, i| {
        if (std.ascii.isUpper(char)) {
            if (i > 0) {
                try result.append('_');
            }
            try result.append(std.ascii.toLower(char));
        } else {
            try result.append(char);
        }
    }

    return result.toOwnedSlice();
}

fn generateProxy(allocator: std.mem.Allocator, file_path: []const u8, struct_name: []const u8, output_dir: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
    defer allocator.free(content);

    const snake_case_name = try structNameToSnakeCase(allocator, struct_name);
    defer allocator.free(snake_case_name);

    const output_filename = try std.fmt.allocPrint(allocator, "{s}/{s}_proxy.gen.zig", .{ output_dir, snake_case_name });
    defer allocator.free(output_filename);

    std.fs.cwd().makePath(output_dir) catch {};

    const output_file = try std.fs.cwd().createFile(output_filename, .{});
    defer output_file.close();
    const writer = output_file.writer();

    var regular_methods = std.ArrayList(MethodInfo).init(allocator);
    defer regular_methods.deinit();

    var lines = std.mem.splitAny(u8, content, "\n");
    var inside_target_struct = false;
    var brace_depth: i32 = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (!inside_target_struct) {
            if (std.mem.indexOf(u8, trimmed, "= struct {")) |_| {
                if (extractStructName(trimmed)) |name| {
                    if (std.mem.eql(u8, name, struct_name)) {
                        inside_target_struct = true;
                        brace_depth = 1;
                        continue;
                    }
                }
            }
            continue;
        }

        for (trimmed) |char| {
            if (char == '{') brace_depth += 1;
            if (char == '}') brace_depth -= 1;
        }

        if (brace_depth == 0) {
            break;
        }

        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            const brace_pos = std.mem.indexOf(u8, trimmed, "{") orelse continue;
            const signature = trimmed[0..brace_pos];
            const method_info = parseMethodSignature(signature) orelse continue;

            if (!std.mem.eql(u8, method_info.name, "init") and !std.mem.eql(u8, method_info.name, "deinit")) {
                try regular_methods.append(method_info);
            }
        }
    }

    try generateActorProxy(allocator, writer, struct_name, regular_methods.items, file_path, output_dir, content);
}

fn calculateRelativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_file: []const u8) ![]u8 {
    const from_normalized = try std.fs.path.resolve(allocator, &[_][]const u8{from_dir});
    defer allocator.free(from_normalized);

    const to_normalized = try std.fs.path.resolve(allocator, &[_][]const u8{to_file});
    defer allocator.free(to_normalized);

    return std.fs.path.relative(allocator, from_normalized, to_normalized);
}

fn extractAndCopyImports(allocator: std.mem.Allocator, writer: anytype, file_content: []const u8, file_path: []const u8, output_dir: []const u8) !void {
    var lines = std.mem.splitAny(u8, file_content, "\n");

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or !std.mem.startsWith(u8, trimmed, "const ")) {
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "@import(") == null) {
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "@import(\"std\")") != null or
            std.mem.indexOf(u8, trimmed, "@import(\"backstage\")") != null or
            std.mem.indexOf(u8, trimmed, "@import(\"testing\")") != null)
        {
            continue;
        }

        if (std.mem.indexOf(u8, trimmed, "generated/") != null and std.mem.indexOf(u8, trimmed, "_proxy.gen.zig") != null) {
            continue;
        }

        if (extractImportInfo(allocator, trimmed)) |import_info| {
            defer allocator.free(import_info.name);
            defer allocator.free(import_info.path);
            defer allocator.free(import_info.member);

            const adjusted_import_path = if (std.mem.endsWith(u8, import_info.path, ".zig"))
                try adjustRelativeImportPath(allocator, import_info.path, file_path, output_dir)
            else
                try allocator.dupe(u8, import_info.path);
            defer allocator.free(adjusted_import_path);

            if (import_info.member.len > 0) {
                try writer.print("const {s} = @import(\"{s}\").{s};\n", .{ import_info.name, adjusted_import_path, import_info.member });
            } else {
                try writer.print("const {s} = @import(\"{s}\");\n", .{ import_info.name, adjusted_import_path });
            }
        } else |_| {
            continue;
        }
    }
}

const ImportInfo = struct {
    name: []u8,
    path: []u8,
    member: []u8,
};

fn extractImportInfo(allocator: std.mem.Allocator, line: []const u8) !ImportInfo {
    if (!std.mem.startsWith(u8, line, "const ")) return error.InvalidImport;

    const after_const = line[6..];
    const eq_pos = std.mem.indexOf(u8, after_const, " =") orelse return error.InvalidImport;
    const name = std.mem.trim(u8, after_const[0..eq_pos], " \t");

    const import_start = std.mem.indexOf(u8, line, "@import(\"") orelse return error.InvalidImport;
    const path_start = import_start + 9;
    const path_end = std.mem.indexOf(u8, line[path_start..], "\"") orelse return error.InvalidImport;
    const path = line[path_start .. path_start + path_end];

    const after_import = line[path_start + path_end + 1 ..];
    var member: []const u8 = "";

    if (std.mem.startsWith(u8, after_import, ").")) {
        const member_start = 2;
        const member_part = after_import[member_start..];
        if (std.mem.indexOf(u8, member_part, ";")) |semicolon_pos| {
            member = std.mem.trim(u8, member_part[0..semicolon_pos], " \t");
        }
    }

    return ImportInfo{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
        .member = try allocator.dupe(u8, member),
    };
}

fn adjustRelativeImportPath(allocator: std.mem.Allocator, original_path: []const u8, from_file: []const u8, to_dir: []const u8) ![]u8 {
    const from_dir = std.fs.path.dirname(from_file) orelse ".";

    const resolved_target = try std.fs.path.resolve(allocator, &[_][]const u8{ from_dir, original_path });
    defer allocator.free(resolved_target);

    return calculateRelativePath(allocator, to_dir, resolved_target);
}

fn generateActorProxy(allocator: std.mem.Allocator, writer: anytype, struct_name: []const u8, methods: []const MethodInfo, file_path: []const u8, output_dir: []const u8, file_content: []const u8) !void {
    const relative_import = try calculateRelativePath(allocator, output_dir, file_path);
    defer allocator.free(relative_import);

    var types_to_import = std.StringHashMap(void).init(allocator);
    defer {
        var iterator = types_to_import.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        types_to_import.deinit();
    }

    for (methods) |method| {
        try collectTypesToImport(allocator, method.params, file_content, struct_name, &types_to_import);
    }

    try writer.print(
        \\const std = @import("std");
        \\const backstage = @import("backstage");
        \\const Context = backstage.Context;
        \\const MethodCall = backstage.MethodCall;
        \\const {s} = @import("{s}").{s};
        \\
    , .{ struct_name, relative_import, struct_name });

    var type_iterator = types_to_import.iterator();
    while (type_iterator.next()) |entry| {
        try writer.print("const {s} = @import(\"{s}\").{s};\n", .{ entry.key_ptr.*, relative_import, entry.key_ptr.* });
    }

    try extractAndCopyImports(allocator, writer, file_content, file_path, output_dir);

    try writer.print(
        \\
        \\pub const {s}Proxy = struct {{
        \\    pub const is_proxy = true;
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
    , .{ struct_name, struct_name, struct_name });

    try generateMethodTable(allocator, writer, methods, struct_name, file_content, &types_to_import);

    for (methods, 0..) |method, i| {
        try generateProxyMethod(allocator, writer, method, i, struct_name, file_content, &types_to_import);
    }

    try generateDispatchFunction(writer, methods.len);

    try writer.writeAll("};\n");
}

fn generateMethodTable(allocator: std.mem.Allocator, writer: anytype, methods: []const MethodInfo, struct_name: []const u8, file_content: []const u8, types_to_import: *std.StringHashMap(void)) !void {
    try writer.print("    const MethodFn = *const fn (*Self, []const u8) anyerror!void;\n\n", .{});

    for (methods, 0..) |method, i| {
        try generateMethodWrapper(allocator, writer, method, i, struct_name, file_content, types_to_import);
    }

    try writer.print("    const method_table = [_]MethodFn{{\n", .{});
    for (methods, 0..) |_, i| {
        try writer.print("        methodWrapper{d},\n", .{i});
    }
    try writer.writeAll("    };\n\n");
}

fn generateMethodWrapper(allocator: std.mem.Allocator, writer: anytype, method: MethodInfo, index: usize, struct_name: []const u8, file_content: []const u8, types_to_import: *std.StringHashMap(void)) !void {
    try writer.print("    fn methodWrapper{d}(self: *Self, params_json: []const u8) !void {{\n", .{index});

    const param_names = try extractParamNames(allocator, method.params);
    defer {
        for (param_names) |name| {
            if (std.mem.startsWith(u8, name, "unused_param")) {
                allocator.free(name);
            }
        }
        allocator.free(param_names);
    }

    if (param_names.len > 0) {
        try writer.writeAll("        const params = try std.json.parseFromSlice(struct {\n");

        var param_split = std.mem.splitAny(u8, method.params, ",");
        var unused_count: u32 = 1;
        var param_index: u32 = 0;

        while (param_split.next()) |param| {
            const trimmed = std.mem.trim(u8, param, " \t");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                if (param_index == 0) {
                    param_index += 1;
                    continue;
                }

                const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const param_type = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
                const resolved_type = try resolveTypeForProxy(allocator, param_type, file_content, struct_name, types_to_import);
                defer allocator.free(resolved_type);

                const display_param_name = if (std.mem.eql(u8, param_name, "_")) blk: {
                    const name = try std.fmt.allocPrint(allocator, "unused_param{d}", .{unused_count});
                    unused_count += 1;
                    break :blk name;
                } else param_name;

                defer if (std.mem.startsWith(u8, display_param_name, "unused_param")) allocator.free(display_param_name);
                try writer.print("            {s}: {s},\n", .{ display_param_name, resolved_type });
                param_index += 1;
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

fn generateProxyMethod(allocator: std.mem.Allocator, writer: anytype, method_info: MethodInfo, method_index: usize, struct_name: []const u8, file_content: []const u8, types_to_import: *std.StringHashMap(void)) !void {
    const param_names = try extractParamNames(allocator, method_info.params);
    defer {
        for (param_names) |name| {
            if (std.mem.startsWith(u8, name, "unused_param")) {
                allocator.free(name);
            }
        }
        allocator.free(param_names);
    }

    try writer.print("    pub fn {s}(self: *Self", .{method_info.name});

    if (method_info.params.len > 0) {
        var param_split = std.mem.splitAny(u8, method_info.params, ",");
        var unused_count: u32 = 1;
        var param_index: u32 = 0;

        while (param_split.next()) |param| {
            const trimmed = std.mem.trim(u8, param, " \t");
            if (trimmed.len == 0) continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
                if (param_index == 0) {
                    param_index += 1;
                    continue;
                }

                const param_name = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
                const param_type = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");
                const resolved_type = try resolveTypeForProxy(allocator, param_type, file_content, struct_name, types_to_import);
                defer allocator.free(resolved_type);

                const display_param_name = if (std.mem.eql(u8, param_name, "_")) blk: {
                    const name = try std.fmt.allocPrint(allocator, "unused_param{d}", .{unused_count});
                    unused_count += 1;
                    break :blk name;
                } else param_name;

                defer if (std.mem.startsWith(u8, display_param_name, "unused_param")) allocator.free(display_param_name);
                try writer.print(", {s}: {s}", .{ display_param_name, resolved_type });
                param_index += 1;
            } else {
                try writer.print(", {s}", .{trimmed});
            }
        }
    }

    try writer.writeAll(") !void {\n");

    if (param_names.len == 0) {
        try writer.writeAll("        const params_str = \"\";\n");
    } else {
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
    }

    try writer.print(
        \\        const method_call = MethodCall{{
        \\            .method_id = {d},
        \\            .params = params_str,
        \\        }};
        \\        try self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);
    , .{method_index});

    try writer.writeAll("    }\n\n");
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
