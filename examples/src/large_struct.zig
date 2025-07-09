const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;

const TestActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    message_received: bool = false,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn receive(self: *Self, _: Envelope) !void {
        self.message_received = true;
    }

    pub fn deinit(_: *Self) !void {}
};

const LargeStruct = struct {
    big_message: []const u8,
    big_message_list: []const []const u8,

    const Self = @This();

    pub fn encode(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
      var json_bytes = std.ArrayList(u8).init(allocator);
        try std.json.stringify(self, .{}, json_bytes.writer());
        return json_bytes.toOwnedSlice();
    }
};

test "Large struct" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    var big_message_list = std.ArrayList([]const u8).init(allocator);
    defer big_message_list.deinit();
    for (0..20) |_| {
        try big_message_list.append("Lorem ipsum dolor sit amet consectetur adipiscing elit. Quisque faucibus ex sapien vitae pellentesque sem placerat. In id cursus mi pretium tellus duis convallis. Tempus leo eu aenean sed diam urna tempor. Pulvinar vivamus fringilla lacus nec metus bibendum egestas. Iaculis massa nisl malesuada lacinia integer nunc posuere. Ut hendrerit semper vel class aptent taciti sociosqu. Ad litora torquent per conubia nostra inceptos himenaeos.");
    }
    const hello_world_struct = LargeStruct{
        .big_message = "Lorem ipsum dolor sit amet consectetur adipiscing elit. Quisque faucibus ex sapien vitae pellentesque sem placerat. In id cursus mi pretium tellus duis convallis. Tempus leo eu aenean sed diam urna tempor. Pulvinar vivamus fringilla lacus nec metus bibendum egestas. Iaculis massa nisl malesuada lacinia integer nunc posuere. Ut hendrerit semper vel class aptent taciti sociosqu. Ad litora torquent per conubia nostra inceptos himenaeos.",
        .big_message_list = big_message_list.items,
    };
    const test_actor = try engine.spawnActor(TestActor, .{
        .id = "test_actor",
    });
    try engine.send(null, "test_actor", hello_world_struct);
    try engine.loop.run(.once);
    try testing.expect(test_actor.message_received);
}
