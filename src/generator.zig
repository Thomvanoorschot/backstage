const std = @import("std");

const ACTOR_FILE = "examples/src/lazy_actor.zig";
const ACTOR_NAME = "LazyActor";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = try std.fs.cwd().readFileAlloc(allocator, ACTOR_FILE, 1024 * 1024);
    defer allocator.free(content);

    const stdout = std.io.getStdOut().writer();

    try stdout.print(
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
    , .{ ACTOR_NAME, ACTOR_NAME });

    var lines = std.mem.splitAny(u8, content, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "pub fn ")) {
            if (std.mem.indexOf(u8, trimmed, "{")) |brace_pos| {
                const signature = trimmed[0..brace_pos];
                try stdout.print("    {s}{{\n", .{signature});

                try suppressParameters(stdout, signature);

                try stdout.writeAll("        // TODO: implement\n    }\n\n");
            }
        }
    }

    try stdout.writeAll("};\n");
}

fn suppressParameters(stdout: anytype, signature: []const u8) !void {
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

            if (std.mem.eql(u8, param_name, "_")) continue;

            try stdout.print("        _ = {s};\n", .{param_name});
        }
    }
}
