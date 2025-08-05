const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const MultipleMessagesActorProxy = @import("generated/multiple_messages_actor_proxy.gen.zig").MultipleMessagesActorProxy;

// @generate-proxy
pub const MultipleMessagesActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    message_received_count: u64 = 0,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn logHelloWorld(self: *Self, _: HelloWorldStruct) !void {
        self.message_received_count += 1;
        std.log.info("Message {} received", .{self.message_received_count});
    }

    pub fn deinit(_: *Self) !void {}
};

pub const HelloWorldStruct = struct {
    message: []const u8,

    const Self = @This();

    pub fn encode(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return try allocator.dupe(u8, self.message);
    }
};

test "Hello, World!" {
    testing.log_level = .info;
    var engine = try backstage.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const hello_world_struct = HelloWorldStruct{
        .message = "Hello, world!",
    };
    const test_actor = try engine.getActor(MultipleMessagesActorProxy, "test_actor");
    try test_actor.logHelloWorld(hello_world_struct);
    try test_actor.logHelloWorld(hello_world_struct);
    try test_actor.logHelloWorld(hello_world_struct);
    try test_actor.logHelloWorld(hello_world_struct);
    try engine.loop.run(.once);
    try testing.expect(test_actor.underlying.message_received_count == 4);
}
