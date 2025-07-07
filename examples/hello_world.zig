const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;

const HelloWorldActor = struct {
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const hello_world_actor = try engine.spawnActor(HelloWorldActor, .{
        .id = "hello_world_actor",
    });
    try engine.send(null, "hello_world_actor", "Hello, world!");
    try engine.loop.run(.once);
    try testing.expect(hello_world_actor.hello_world_received);
}
