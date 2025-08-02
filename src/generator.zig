// const build_options = @import("build_options");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <output_dir> <scan_dir1> [scan_dir2] [...]\n", .{args[0]});
        std.debug.print("Example: {s} src/generated src src/actors\n", .{args[0]});
        return;
    }

    const output_dir = args[1];
    const scan_dirs = args[2..];

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
    struct_name: []u8,
};

const MethodInfo = struct {
    name: []u8,
    params: []ParamInfo,
    has_return: bool,

    const ParamInfo = struct {
        name: []u8,
        type_name: []u8,
    };

    pub fn deinit(self: MethodInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.params) |param| {
            allocator.free(param.name);
            allocator.free(param.type_name);
        }
        allocator.free(self.params);
    }
};

const AliasInfo = struct {
    name: []u8,
    module_name: []u8,
    member_name: []u8,

    pub fn deinit(self: AliasInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.module_name);
        allocator.free(self.member_name);
    }
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

        if (try findMarkedActorsInFile(allocator, file_path)) |actors| {
            defer {
                for (actors.items) |actor_name| {
                    allocator.free(actor_name);
                }
                actors.deinit();
            }
            for (actors.items) |struct_name| {
                try actor_files.append(.{
                    .path = try allocator.dupe(u8, file_path),
                    .struct_name = try allocator.dupe(u8, struct_name),
                });
            }
        }
    }
}

fn findMarkedActorsInFile(allocator: std.mem.Allocator, file_path: []const u8) !?std.ArrayList([]u8) {
    const content = std.fs.cwd().readFileAllocOptions(allocator, file_path, 1024 * 1024, null, @enumFromInt(1), 0) catch return null;
    defer allocator.free(content);

    var ast = std.zig.Ast.parse(allocator, content, .zig) catch return null;
    defer ast.deinit(allocator);

    return findMarkedActorsHybrid(allocator, content, &ast);
}

fn findMarkedActorsHybrid(allocator: std.mem.Allocator, source: []const u8, ast: *std.zig.Ast) !?std.ArrayList([]u8) {
    var actors = std.ArrayList([]u8).init(allocator);

    var search_start: usize = 0;
    while (std.mem.indexOf(u8, source[search_start..], "// @generate-proxy")) |comment_pos| {
        const absolute_pos = search_start + comment_pos;

        const line_num = countLinesBeforePos(source, absolute_pos);

        if (try findStructAfterLine(allocator, ast, source, line_num)) |struct_name| {
            try actors.append(struct_name);
        }

        search_start = absolute_pos + 1;
    }

    return if (actors.items.len == 0) null else actors;
}

fn countLinesBeforePos(source: []const u8, pos: usize) u32 {
    var line_count: u32 = 0;
    for (source[0..pos]) |char| {
        if (char == '\n') {
            line_count += 1;
        }
    }
    return line_count;
}

fn findStructAfterLine(allocator: std.mem.Allocator, ast: *std.zig.Ast, source: []const u8, target_line: u32) !?[]u8 {
    const node_tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    const token_starts = ast.tokens.items(.start);

    for (node_tags, 0..) |tag, i| {
        if (tag == .simple_var_decl or tag == .local_var_decl or tag == .global_var_decl) {
            const main_token = main_tokens[@intFromEnum(@as(std.zig.Ast.Node.Index, @enumFromInt(@as(u32, @intCast(i)))))];
            const token_start = token_starts[main_token];

            const token_line = countLinesBeforePos(source, token_start);

            if (token_line > target_line and token_line <= target_line + 3) {
                if (try extractVarNameFromDecl(allocator, ast, @enumFromInt(@as(u32, @intCast(i))))) |var_name| {
                    return var_name;
                }
            }
        }
    }

    return null;
}

fn extractVarNameFromDecl(allocator: std.mem.Allocator, ast: *std.zig.Ast, node_idx: std.zig.Ast.Node.Index) !?[]u8 {
    const main_tokens = ast.nodes.items(.main_token);
    const token_tags = ast.tokens.items(.tag);

    var token_idx = main_tokens[@intFromEnum(node_idx)];

    while (token_idx < token_tags.len) : (token_idx += 1) {
        const tag = token_tags[token_idx];

        if (tag == .identifier) {
            if (try isStructDeclaration(ast, token_idx)) {
                const name = ast.tokenSlice(token_idx);
                return try allocator.dupe(u8, name);
            }
        }
    }

    return null;
}

fn isStructDeclaration(ast: *std.zig.Ast, identifier_token: u32) !bool {
    const token_tags = ast.tokens.items(.tag);

    var token_idx = identifier_token + 1;
    var tokens_to_check: u32 = 5;

    while (token_idx < token_tags.len and tokens_to_check > 0) : ({
        token_idx += 1;
        tokens_to_check -= 1;
    }) {
        const tag = token_tags[token_idx];

        if (tag == .keyword_struct) {
            return true;
        }

        if (tag != .equal and tag != .l_brace and tag != .r_brace and tag != .semicolon) {
            continue;
        }
    }

    return false;
}

fn generateProxy(allocator: std.mem.Allocator, file_path: []const u8, struct_name: []const u8, output_dir: []const u8) !void {
    const content = try std.fs.cwd().readFileAllocOptions(allocator, file_path, 1024 * 1024, null, @enumFromInt(1), 0);
    defer allocator.free(content);

    var ast = try std.zig.Ast.parse(allocator, content, .zig);
    defer ast.deinit(allocator);

    const snake_case_name = try structNameToSnakeCase(allocator, struct_name);
    defer allocator.free(snake_case_name);

    const output_filename = try std.fmt.allocPrint(allocator, "{s}/{s}_proxy.gen.zig", .{ output_dir, snake_case_name });
    defer allocator.free(output_filename);

    std.fs.cwd().makePath(output_dir) catch {};

    const output_file = try std.fs.cwd().createFile(output_filename, .{});
    defer output_file.close();
    const writer = output_file.writer();

    const methods = try extractMethodsFromStruct(allocator, &ast, struct_name);
    defer {
        for (methods.items) |method| {
            method.deinit(allocator);
        }
        methods.deinit();
    }

    try generateActorProxy(allocator, writer, struct_name, methods.items, file_path, output_dir);
}

fn extractMethodsFromStruct(allocator: std.mem.Allocator, ast: *std.zig.Ast, target_struct_name: []const u8) !std.ArrayList(MethodInfo) {
    var methods = std.ArrayList(MethodInfo).init(allocator);

    const struct_node = try findStructNodeByName(ast, target_struct_name) orelse {
        std.log.warn("Could not find struct '{s}' in AST", .{target_struct_name});
        return methods;
    };

    try extractMethodsFromStructNode(allocator, ast, struct_node, &methods);

    return methods;
}

fn findStructNodeByName(ast: *std.zig.Ast, struct_name: []const u8) !?std.zig.Ast.Node.Index {
    const node_tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    const token_tags = ast.tokens.items(.tag);

    for (node_tags, 0..) |tag, i| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl => {
                const node_idx: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
                const main_token = main_tokens[@intFromEnum(node_idx)];

                var token_idx = main_token;

                if (token_idx < token_tags.len and token_tags[token_idx] == .keyword_pub) {
                    token_idx += 1;
                }

                if (token_idx < token_tags.len and token_tags[token_idx] == .keyword_const) {
                    token_idx += 1;
                }

                if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
                    const name = ast.tokenSlice(token_idx);
                    if (std.mem.eql(u8, name, struct_name)) {
                        token_idx += 1;
                        while (token_idx < token_tags.len and token_tags[token_idx] != .keyword_struct) {
                            if (token_tags[token_idx] == .semicolon) break;
                            token_idx += 1;
                        }
                        if (token_idx < token_tags.len and token_tags[token_idx] == .keyword_struct) {
                            return node_idx;
                        }
                    }
                }
            },
            else => continue,
        }
    }

    return null;
}

fn extractMethodsFromStructNode(allocator: std.mem.Allocator, ast: *std.zig.Ast, struct_node: std.zig.Ast.Node.Index, methods: *std.ArrayList(MethodInfo)) !void {
    const node_tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    const token_tags = ast.tokens.items(.tag);

    const struct_main_token = main_tokens[@intFromEnum(struct_node)];
    var token_idx = struct_main_token;

    while (token_idx < token_tags.len and token_tags[token_idx] != .l_brace) {
        token_idx += 1;
    }

    if (token_idx >= token_tags.len) return;

    const struct_start_token = token_idx;
    token_idx += 1;

    var brace_depth: u32 = 1;
    var struct_end_token = token_idx;

    while (struct_end_token < token_tags.len and brace_depth > 0) {
        switch (token_tags[struct_end_token]) {
            .l_brace => brace_depth += 1,
            .r_brace => brace_depth -= 1,
            else => {},
        }
        if (brace_depth > 0) struct_end_token += 1;
    }

    if (brace_depth > 0) return;

    for (node_tags, 0..) |tag, i| {
        if (tag == .fn_decl) {
            const fn_node: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
            const fn_main_token = main_tokens[@intFromEnum(fn_node)];

            if (fn_main_token > struct_start_token and fn_main_token < struct_end_token) {
                if (try extractMethodInfoFromFunctionNode(allocator, ast, fn_node, token_tags, main_tokens)) |method_info| {
                    if (!std.mem.eql(u8, method_info.name, "init") and
                        !std.mem.eql(u8, method_info.name, "deinit"))
                    {
                        try methods.append(method_info);
                    } else {
                        method_info.deinit(allocator);
                    }
                }
            }
        }
    }
}

fn extractMethodInfoFromFunctionNode(allocator: std.mem.Allocator, ast: *std.zig.Ast, fn_node: std.zig.Ast.Node.Index, token_tags: []const std.zig.Token.Tag, main_tokens: []const std.zig.Ast.TokenIndex) !?MethodInfo {
    const fn_token = main_tokens[@intFromEnum(fn_node)];
    var token_idx = fn_token;
    var is_public = false;

    var search_limit: u32 = 5;
    while (token_idx > 0 and search_limit > 0) {
        token_idx -= 1;
        search_limit -= 1;
        const tag = token_tags[token_idx];

        switch (tag) {
            .keyword_pub => {
                is_public = true;
                break;
            },
            .keyword_const, .keyword_var, .keyword_fn => break,
            else => continue,
        }
    }

    if (!is_public) return null;

    const name_token = fn_token + 1;
    const fn_name = ast.tokenSlice(name_token);

    const params = try extractFunctionParameters(allocator, ast, fn_token);

    return MethodInfo{
        .name = try allocator.dupe(u8, fn_name),
        .params = params,
        .has_return = false,
    };
}

fn extractFunctionParameters(allocator: std.mem.Allocator, ast: *std.zig.Ast, fn_token: u32) ![]MethodInfo.ParamInfo {
    const token_tags = ast.tokens.items(.tag);
    var params = std.ArrayList(MethodInfo.ParamInfo).init(allocator);
    defer params.deinit();

    var token_idx = fn_token;
    while (token_idx < token_tags.len and token_tags[token_idx] != .l_paren) {
        token_idx += 1;
    }

    if (token_idx >= token_tags.len) {
        return try allocator.alloc(MethodInfo.ParamInfo, 0);
    }

    token_idx += 1;
    var unnamed_param_count: u32 = 0;
    var param_position: u32 = 0;

    while (token_idx < token_tags.len and token_tags[token_idx] != .r_paren) {
        const tag = token_tags[token_idx];

        if (tag == .identifier) {
            const param_name_slice = ast.tokenSlice(token_idx);

            if (param_position == 0) {
                while (token_idx < token_tags.len and
                    token_tags[token_idx] != .comma and
                    token_tags[token_idx] != .r_paren)
                {
                    token_idx += 1;
                }
                if (token_idx < token_tags.len and token_tags[token_idx] == .comma) {
                    token_idx += 1;
                }
                param_position += 1;
                continue;
            }

            var param_name: []u8 = undefined;
            if (std.mem.eql(u8, param_name_slice, "_")) {
                param_name = try std.fmt.allocPrint(allocator, "unused_param{d}", .{unnamed_param_count + 1});
                unnamed_param_count += 1;
            } else {
                param_name = try allocator.dupe(u8, param_name_slice);
            }

            token_idx += 1;

            if (token_idx < token_tags.len and token_tags[token_idx] == .colon) {
                token_idx += 1;
            }

            const type_start = token_idx;
            var type_end = token_idx;
            var paren_depth: u32 = 0;
            var bracket_depth: u32 = 0;

            while (type_end < token_tags.len) {
                const type_tag = token_tags[type_end];

                switch (type_tag) {
                    .l_paren => paren_depth += 1,
                    .r_paren => {
                        if (paren_depth == 0) break;
                        paren_depth -= 1;
                    },
                    .l_bracket => bracket_depth += 1,
                    .r_bracket => bracket_depth -= 1,
                    .comma => {
                        if (paren_depth == 0 and bracket_depth == 0) break;
                    },
                    else => {},
                }

                type_end += 1;
            }

            var type_str = std.ArrayList(u8).init(allocator);
            defer type_str.deinit();

            for (type_start..type_end) |i| {
                const token_slice_type = ast.tokenSlice(@intCast(i));
                try type_str.appendSlice(token_slice_type);

                const current_tag = token_tags[i];
                if (current_tag == .l_bracket or current_tag == .r_bracket) {} else if (i + 1 < type_end) {
                    const next_tag = token_tags[i + 1];
                    if (next_tag != .l_bracket and next_tag != .r_bracket and
                        current_tag != .l_bracket and current_tag != .r_bracket)
                    {
                        try type_str.append(' ');
                    }
                }
            }

            const type_clean = try cleanupTypeString(allocator, type_str.items);

            try params.append(.{
                .name = param_name,
                .type_name = type_clean,
            });

            token_idx = type_end;

            if (token_idx < token_tags.len and token_tags[token_idx] == .comma) {
                token_idx += 1;
            }

            param_position += 1;
        } else {
            token_idx += 1;
        }
    }

    return try params.toOwnedSlice();
}

fn cleanupTypeString(allocator: std.mem.Allocator, type_str: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var last_was_space = false;
    for (type_str) |char| {
        if (char == ' ') {
            if (!last_was_space) {
                try result.append(char);
                last_was_space = true;
            }
        } else {
            try result.append(char);
            last_was_space = false;
        }
    }

    if (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
        _ = result.pop();
    }

    return try result.toOwnedSlice();
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

fn generateActorProxy(allocator: std.mem.Allocator, writer: anytype, struct_name: []const u8, methods: []const MethodInfo, file_path: []const u8, output_dir: []const u8) !void {
    const relative_import = try calculateRelativePath(allocator, output_dir, file_path);
    defer allocator.free(relative_import);

    const file_content = try std.fs.cwd().readFileAllocOptions(allocator, file_path, 1024 * 1024, null, @enumFromInt(1), 0);
    defer allocator.free(file_content);

    var ast = try std.zig.Ast.parse(allocator, file_content, .zig);
    defer ast.deinit(allocator);

    const imports = try findImportsInAst(allocator, &ast);
    defer {
        for (imports.items) |import_info| {
            allocator.free(import_info.name);
            allocator.free(import_info.path);
            allocator.free(import_info.member);
        }
        imports.deinit();
    }

    const aliases = try findAliasesInAst(allocator, &ast, imports.items);
    defer {
        for (aliases.items) |alias_info| {
            alias_info.deinit(allocator);
        }
        aliases.deinit();
    }

    var custom_types = std.ArrayList([]u8).init(allocator);
    defer {
        for (custom_types.items) |type_name| {
            allocator.free(type_name);
        }
        custom_types.deinit();
    }

    for (methods) |method| {
        for (method.params) |param| {
            const clean_type_name = try cleanupAstTypeString(allocator, param.type_name);
            defer allocator.free(clean_type_name);

            if (isCustomType(clean_type_name)) {
                var already_exists = false;
                for (custom_types.items) |existing_type| {
                    if (std.mem.eql(u8, existing_type, clean_type_name)) {
                        already_exists = true;
                        break;
                    }
                }

                if (!already_exists) {
                    try custom_types.append(try allocator.dupe(u8, clean_type_name));
                }
            }
        }
    }

    try writer.writeAll(
        \\const std = @import("std");
        \\const backstage = @import("backstage");
        \\const Context = backstage.Context;
        \\const MethodCall = backstage.MethodCall;
        \\const zborParse = backstage.zborParse;
        \\const zborStringify = backstage.zborStringify;
        \\const zborDataItem = backstage.zborDataItem;
        \\
    );

    try writer.print("const {s} = @import(\"{s}\").{s};\n", .{ struct_name, relative_import, struct_name });

    for (custom_types.items) |type_name| {
        if (try isTypeDefinedInAst(&ast, type_name)) {
            try writer.print("const {s} = @import(\"{s}\").{s};\n", .{ type_name, relative_import, type_name });
        }
    }

    try generateImportsFromAst(allocator, writer, imports.items, file_path, output_dir);

    try generateAliasesFromAst(allocator, writer, aliases.items, imports.items);

    try writer.writeAll(
        \\
        \\pub const 
    );
    try writer.print("{s}Proxy = struct {{\n", .{struct_name});
    try writer.writeAll(
        \\    pub const is_proxy = true;
        \\    ctx: *Context,
        \\    allocator: std.mem.Allocator,
        \\    underlying: *
    );
    try writer.print("{s},\n", .{struct_name});
    try writer.writeAll(
        \\    
        \\    const Self = @This();
        \\
        \\    pub const Method = enum(u32) {
        \\
    );

    // Generate method enum values
    for (methods, 0..) |method, i| {
        try writer.print("        {s} = {d},\n", .{ method.name, i });
    }

    try writer.writeAll(
        \\    };
        \\
        \\    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        \\        const self = try allocator.create(Self);
        \\        const underlying = try 
    );
    try writer.print("{s}.init(ctx, allocator);\n", .{struct_name});
    try writer.writeAll(
        \\        self.* = .{
        \\            .ctx = ctx,
        \\            .allocator = allocator,
        \\            .underlying = underlying,
        \\        };
        \\        return self;
        \\    }
        \\
        \\    pub fn deinit(self: *Self) !void {
        \\        try self.underlying.deinit();
        \\        self.allocator.destroy(self);
        \\    }
        \\
    );

    for (methods, 0..) |method, i| {
        try writer.print("    inline fn methodWrapper{d}(self: *Self, params: []const u8) !void {{\n", .{i});

        if (method.params.len == 0) {
            try writer.writeAll("        _ = params;\n");
            try writer.print("        return self.underlying.{s}();\n", .{method.name});
        } else if (method.params.len == 1) {
            const clean_type = try cleanupAstTypeString(allocator, method.params[0].type_name);
            defer allocator.free(clean_type);
            try writer.print("        const result = try zborParse({s}, try zborDataItem.new(params), .{{ .allocator = self.allocator }});\n", .{clean_type});
            try writer.print("        return self.underlying.{s}(result);\n", .{method.name});
        } else {
            try writer.writeAll("        const result = try zborParse(struct {\n");
            for (method.params) |param| {
                const clean_type = try cleanupAstTypeString(allocator, param.type_name);
                defer allocator.free(clean_type);
                try writer.print("            {s}: {s},\n", .{ param.name, clean_type });
            }
            try writer.writeAll("        }, try zborDataItem.new(params), .{ .allocator = self.allocator });\n");

            try writer.print("        return self.underlying.{s}(", .{method.name});
            for (method.params, 0..) |param, p| {
                if (p > 0) try writer.writeAll(", ");
                try writer.print("result.{s}", .{param.name});
            }
            try writer.writeAll(");\n");
        }
        try writer.writeAll("    }\n\n");
    }

    for (methods, 0..) |method, i| {
        try writer.print("    pub inline fn {s}(self: *Self", .{method.name});

        for (method.params) |param| {
            const clean_type = try cleanupAstTypeString(allocator, param.type_name);
            defer allocator.free(clean_type);
            try writer.print(", {s}: {s}", .{ param.name, clean_type });
        }
        try writer.writeAll(") !void {\n");

        if (method.params.len == 0) {
            try writer.print(
                \\        const method_call = MethodCall{{
                \\            .method_id = {d},
                \\            .params = "",
                \\        }};
                \\        return self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);
            , .{i});
        } else {
            try writer.writeAll("        var params_str = std.ArrayList(u8).init(self.allocator);\n");
            try writer.writeAll("        defer params_str.deinit();\n");

            if (method.params.len == 1) {
                try writer.print("        try zborStringify({s}, .{{}}, params_str.writer());\n", .{method.params[0].name});
            } else {
                try writer.writeAll("        try zborStringify(.{");
                for (method.params, 0..) |param, p| {
                    if (p > 0) try writer.writeAll(", ");
                    try writer.print(".{s} = {s}", .{ param.name, param.name });
                }
                try writer.writeAll("}, .{}, params_str.writer());\n");
            }

            try writer.print(
                \\        const method_call = MethodCall{{
                \\            .method_id = {d},
                \\            .params = params_str.items,
                \\        }};
                \\        return self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);
            , .{i});
        }
        try writer.writeAll("    }\n\n");
    }

    try writer.writeAll(
        \\    pub inline fn dispatchMethod(self: *Self, method_call: MethodCall) !void {
        \\        return switch (method_call.method_id) {
    );

    for (0..methods.len) |i| {
        try writer.print("            {d} => methodWrapper{d}(self, method_call.params),\n", .{ i, i });
    }

    try writer.writeAll(
        \\            else => error.UnknownMethod,
        \\        };
        \\    }
        \\};
        \\
    );
}

fn findImportsInAst(allocator: std.mem.Allocator, ast: *std.zig.Ast) !std.ArrayList(ImportInfo) {
    var imports = std.ArrayList(ImportInfo).init(allocator);

    const node_tags = ast.nodes.items(.tag);

    for (node_tags, 0..) |tag, i| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl => {
                const node_idx: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
                if (try extractImportFromNode(allocator, ast, node_idx)) |import_info| {
                    try imports.append(import_info);
                }
            },
            else => continue,
        }
    }

    return imports;
}

const ImportInfo = struct {
    name: []u8,
    path: []u8,
    member: []u8,
};

fn extractImportFromNode(allocator: std.mem.Allocator, ast: *std.zig.Ast, node_idx: std.zig.Ast.Node.Index) !?ImportInfo {
    const main_tokens = ast.nodes.items(.main_token);
    const token_tags = ast.tokens.items(.tag);

    const main_token = main_tokens[@intFromEnum(node_idx)];

    var token_idx = main_token;
    var var_name: ?[]const u8 = null;
    var import_path: ?[]const u8 = null;
    var member_name: ?[]const u8 = null;

    if (token_idx < token_tags.len and token_tags[token_idx] == .keyword_const) {
        token_idx += 1;
    }

    if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
        var_name = ast.tokenSlice(token_idx);
        token_idx += 1;
    }

    while (token_idx < token_tags.len and token_tags[token_idx] != .equal) {
        token_idx += 1;
    }
    if (token_idx < token_tags.len) token_idx += 1;

    while (token_idx < token_tags.len) {
        if (token_tags[token_idx] == .builtin) {
            const builtin_name = ast.tokenSlice(token_idx);
            if (std.mem.eql(u8, builtin_name, "@import")) {
                token_idx += 1;

                if (token_idx < token_tags.len and token_tags[token_idx] == .l_paren) {
                    token_idx += 1;
                }

                if (token_idx < token_tags.len and token_tags[token_idx] == .string_literal) {
                    const full_literal = ast.tokenSlice(token_idx);
                    if (full_literal.len >= 2) {
                        import_path = full_literal[1 .. full_literal.len - 1];
                    }
                    token_idx += 1;
                }

                if (token_idx < token_tags.len and token_tags[token_idx] == .r_paren) {
                    token_idx += 1;
                }

                if (token_idx < token_tags.len and token_tags[token_idx] == .period) {
                    token_idx += 1;
                    if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
                        member_name = ast.tokenSlice(token_idx);
                    }
                }

                break;
            }
        }
        token_idx += 1;
    }

    if (var_name != null and import_path != null) {
        return ImportInfo{
            .name = try allocator.dupe(u8, var_name.?),
            .path = try allocator.dupe(u8, import_path.?),
            .member = if (member_name) |m| try allocator.dupe(u8, m) else try allocator.dupe(u8, ""),
        };
    }

    return null;
}

fn findAliasesInAst(allocator: std.mem.Allocator, ast: *std.zig.Ast, imports: []const ImportInfo) !std.ArrayList(AliasInfo) {
    var aliases = std.ArrayList(AliasInfo).init(allocator);

    const node_tags = ast.nodes.items(.tag);

    for (node_tags, 0..) |tag, i| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl => {
                const node_idx: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
                if (try extractAliasFromNode(allocator, ast, node_idx, imports)) |alias_info| {
                    try aliases.append(alias_info);
                }
            },
            else => continue,
        }
    }

    return aliases;
}

fn extractAliasFromNode(allocator: std.mem.Allocator, ast: *std.zig.Ast, node_idx: std.zig.Ast.Node.Index, imports: []const ImportInfo) !?AliasInfo {
    const main_tokens = ast.nodes.items(.main_token);
    const token_tags = ast.tokens.items(.tag);

    const main_token = main_tokens[@intFromEnum(node_idx)];

    var token_idx = main_token;
    var var_name: ?[]const u8 = null;
    var module_name: ?[]const u8 = null;
    var member_name: ?[]const u8 = null;

    if (token_idx < token_tags.len and token_tags[token_idx] == .keyword_const) {
        token_idx += 1;
    }

    if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
        var_name = ast.tokenSlice(token_idx);
        token_idx += 1;
    }

    while (token_idx < token_tags.len and token_tags[token_idx] != .equal) {
        token_idx += 1;
    }
    if (token_idx < token_tags.len) token_idx += 1;

    if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
        const potential_module = ast.tokenSlice(token_idx);
        token_idx += 1;

        if (token_idx < token_tags.len and token_tags[token_idx] == .period) {
            token_idx += 1;

            if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
                const potential_member = ast.tokenSlice(token_idx);

                for (imports) |import_info| {
                    if (std.mem.eql(u8, import_info.name, potential_module)) {
                        module_name = potential_module;
                        member_name = potential_member;
                        break;
                    }
                }
            }
        }
    }

    if (var_name != null and module_name != null and member_name != null) {
        return AliasInfo{
            .name = try allocator.dupe(u8, var_name.?),
            .module_name = try allocator.dupe(u8, module_name.?),
            .member_name = try allocator.dupe(u8, member_name.?),
        };
    }

    return null;
}

fn generateAliasesFromAst(allocator: std.mem.Allocator, writer: anytype, aliases: []const AliasInfo, imports: []const ImportInfo) !void {
    _ = allocator;

    for (aliases) |alias_info| {
        var skip_alias = false;
        for (imports) |import_info| {
            if (std.mem.eql(u8, import_info.name, alias_info.module_name)) {
                if (std.mem.eql(u8, import_info.path, "std") or
                    std.mem.eql(u8, import_info.path, "backstage") or
                    std.mem.eql(u8, import_info.path, "testing"))
                {
                    skip_alias = true;
                    break;
                }
            }
        }

        if (!skip_alias) {
            try writer.print("const {s} = {s}.{s};\n", .{ alias_info.name, alias_info.module_name, alias_info.member_name });
        }
    }
}

fn generateImportsFromAst(allocator: std.mem.Allocator, writer: anytype, imports: []const ImportInfo, file_path: []const u8, output_dir: []const u8) !void {
    for (imports) |import_info| {
        if (std.mem.eql(u8, import_info.path, "std") or
            std.mem.eql(u8, import_info.path, "backstage") or
            std.mem.eql(u8, import_info.path, "testing"))
        {
            continue;
        }

        if (std.mem.indexOf(u8, import_info.path, "generated/") != null and
            std.mem.indexOf(u8, import_info.path, "_proxy.gen.zig") != null)
        {
            continue;
        }

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
    }
}

fn isTypeDefinedInAst(ast: *std.zig.Ast, type_name: []const u8) !bool {
    const node_tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    const token_tags = ast.tokens.items(.tag);

    for (node_tags, 0..) |tag, i| {
        switch (tag) {
            .simple_var_decl, .local_var_decl, .global_var_decl => {
                const node_idx: std.zig.Ast.Node.Index = @enumFromInt(@as(u32, @intCast(i)));
                const main_token = main_tokens[@intFromEnum(node_idx)];

                var token_idx = main_token;

                while (token_idx < token_tags.len and
                    (token_tags[token_idx] == .keyword_const or
                        token_tags[token_idx] == .keyword_pub))
                {
                    token_idx += 1;
                }

                if (token_idx < token_tags.len and token_tags[token_idx] == .identifier) {
                    const name = ast.tokenSlice(token_idx);
                    if (std.mem.eql(u8, name, type_name)) {
                        token_idx += 1;
                        while (token_idx < token_tags.len and
                            token_tags[token_idx] != .keyword_struct and
                            token_tags[token_idx] != .keyword_enum and
                            token_tags[token_idx] != .keyword_union)
                        {
                            if (token_tags[token_idx] == .semicolon) break;
                            token_idx += 1;
                        }
                        if (token_idx < token_tags.len and
                            (token_tags[token_idx] == .keyword_struct or
                                token_tags[token_idx] == .keyword_enum or
                                token_tags[token_idx] == .keyword_union))
                        {
                            return true;
                        }
                    }
                }
            },
            else => continue,
        }
    }

    return false;
}

fn cleanupAstTypeString(allocator: std.mem.Allocator, type_str: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < type_str.len) {
        if (i + 2 < type_str.len and
            type_str[i] == ' ' and type_str[i + 1] == '.' and type_str[i + 2] == ' ')
        {
            try result.append('.');
            i += 3;
        } else if (type_str[i] == ' ') {
            if (result.items.len == 0 or result.items[result.items.len - 1] != ' ') {
                try result.append(' ');
            }
            i += 1;
        } else {
            try result.append(type_str[i]);
            i += 1;
        }
    }

    if (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
        _ = result.pop();
    }

    return try result.toOwnedSlice();
}

fn adjustRelativeImportPath(allocator: std.mem.Allocator, original_path: []const u8, from_file: []const u8, to_dir: []const u8) ![]u8 {
    const from_dir = std.fs.path.dirname(from_file) orelse ".";

    const resolved_target = try std.fs.path.resolve(allocator, &[_][]const u8{ from_dir, original_path });
    defer allocator.free(resolved_target);

    return calculateRelativePath(allocator, to_dir, resolved_target);
}

fn isCustomType(type_name: []const u8) bool {
    const primitives = [_][]const u8{ "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "bool" };
    for (primitives) |prim| {
        if (std.mem.eql(u8, type_name, prim)) return false;
    }

    if (std.mem.startsWith(u8, type_name, "[]")) return false;
    if (std.mem.startsWith(u8, type_name, "*")) {
        if (std.mem.indexOf(u8, type_name, "Self")) |_| return false;
    }
    if (std.mem.indexOf(u8, type_name, "std.")) |_| return false;
    if (std.mem.indexOf(u8, type_name, " . ")) |_| return false;

    if (std.mem.indexOf(u8, type_name, ".") == null and
        type_name.len > 0 and
        std.ascii.isUpper(type_name[0]))
    {
        return true;
    }

    return false;
}

fn extractBaseTypeName(allocator: std.mem.Allocator, type_name: []const u8) ![]u8 {
    return try allocator.dupe(u8, type_name);
}

fn calculateRelativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_file: []const u8) ![]u8 {
    const from_normalized = try std.fs.path.resolve(allocator, &[_][]const u8{from_dir});
    defer allocator.free(from_normalized);

    const to_normalized = try std.fs.path.resolve(allocator, &[_][]const u8{to_file});
    defer allocator.free(to_normalized);

    return std.fs.path.relative(allocator, from_normalized, to_normalized);
}
