const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;

const TestActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    hello_world_received: bool = false,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn receive(self: *Self, envelope: Envelope) !void {
        if (std.mem.eql(u8, envelope.message, "Hello, world!")) {
            self.hello_world_received = true;
            std.log.info("{s}", .{envelope.message});
        }
    }

    pub fn deinit(_: *Self) !void {}
};

test "Hello, World!" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const test_actor = try engine.spawnActor(TestActor, .{
        .id = "test_actor",
    });
    try engine.send("test_actor", "Hello, world!");
    try engine.loop.run(.once);
    try testing.expect(test_actor.hello_world_received);
}
