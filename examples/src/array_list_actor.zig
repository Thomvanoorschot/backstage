const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const ArrayListActorProxy = @import("generated/array_list_actor_proxy.gen.zig").ArrayListActorProxy;

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
};

pub const ListItem = struct {
    name: []const u8,
    age: u64,
};

test "Hello, World!" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const test_actor = try engine.getActor(ArrayListActorProxy, "test_actor");
    var struct_with_array_list = try StructWithArrayList.init(allocator);
    defer struct_with_array_list.deinit();
    try test_actor.handleStructWithArrayList(struct_with_array_list);
    try engine.loop.run(.once);
    try testing.expect(test_actor.underlying.array_list_received);
}
