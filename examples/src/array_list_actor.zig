const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const ArrayListActorProxy = @import("generated/array_list_actor_proxy.gen.zig").ArrayListActorProxy;
const zborOptions = backstage.zborOptions;
pub const zborStringify = backstage.zborStringify;
pub const zbor = backstage.zbor;

// @generate-proxy
pub const ArrayListActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    array_list_received: bool = false,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn handleStructWithArrayList(self: *Self, message: StructWithArrayList) !void {
        _ = message;
        self.array_list_received = true;
    }

    pub fn deinit(_: *Self) !void {}
};

pub const StructWithArrayList = struct {
    name: []const u8,
    array_list: std.ArrayList(ListItem),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var array_list = std.ArrayList(ListItem).init(allocator);
        try array_list.append(.{ .name = "Alice", .age = 25 });
        try array_list.append(.{ .name = "Bob", .age = 30 });
        return Self{
            .name = "Members",
            .array_list = array_list,
        };
    }

    pub fn deinit(self: *Self) void {
        self.array_list.deinit();
    }

    // With arrayLists we need to manually stringify and parse
    pub fn cborStringify(self: Self, o: zborOptions, out: anytype) !void {
        try zbor.builder.writeMap(out, 2);
        try zbor.builder.writeTextString(out, "name");
        try zbor.builder.writeTextString(out, self.name);
        try zbor.builder.writeTextString(out, "array_list");
        try zborStringify(self.array_list.items, .{ .allocator = o.allocator }, out);
    }

    pub fn cborParse(item: backstage.zborDataItem, options: backstage.zborOptions) !Self {
        var map = if (item.map()) |m| m else return error.UnexpectedItem;

        const allocator = options.allocator orelse return error.AllocatorRequired;
        var result = Self{
            .name = undefined,
            .array_list = std.ArrayList(ListItem).init(allocator),
        };

        while (map.next()) |kv| {
            const key_str = if (kv.key.string()) |s| s else continue;
            if (std.mem.eql(u8, key_str, "name")) {
                result.name = try backstage.zborParse([]const u8, kv.value, options);
            } else if (std.mem.eql(u8, key_str, "array_list")) {
                const items = try backstage.zborParse([]const ListItem, kv.value, options);
                try result.array_list.appendSlice(items);
                allocator.free(items);
            }
        }

        return result;
    }
};

pub const ListItem = struct {
    name: []const u8,
    age: u64,
};

test "Hello, World!" {
    testing.log_level = .info;
    var engine = try backstage.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const test_actor = try engine.getActor(ArrayListActorProxy, "test_actor");
    var struct_with_array_list = try StructWithArrayList.init(std.testing.allocator);
    defer struct_with_array_list.deinit();
    try test_actor.handleStructWithArrayList(struct_with_array_list);
    try engine.loop.run(.once);
    try testing.expect(test_actor.underlying.array_list_received);
}
