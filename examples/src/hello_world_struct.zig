const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const HelloWorldStructActorProxy = @import("generated/hello_world_struct_actor_proxy.gen.zig").HelloWorldStructActorProxy;

// @generate-proxy
pub const HelloWorldStructActor = struct {
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

    pub fn logHelloWorld(self: *Self, s: HelloWorldStruct) !void {
        if (std.mem.eql(u8, s.message, "Hello, world!")) {
            self.hello_world_received = true;
            std.log.info("{s}", .{s.message});
        }
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
    const test_actor = try engine.getActor(HelloWorldStructActorProxy, "test_actor");
    try test_actor.logHelloWorld(hello_world_struct);
    try engine.loop.run(.once);
    try testing.expect(test_actor.underlying.hello_world_received);
}
