const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const HelloWorldStringActorProxy = @import("generated/hello_world_string_actor_proxy.gen.zig").HelloWorldStringActorProxy;

// @generate-proxy
pub const HelloWorldStringActor = struct {
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

    pub fn logHelloWorld(self: *Self, message: []const u8) !void {
        if (std.mem.eql(u8, message, "Hello, world!")) {
            self.hello_world_received = true;
            std.log.info("{s}", .{message});
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

    const test_actor = try engine.getActor(HelloWorldStringActorProxy, "test_actor");
    try test_actor.logHelloWorld("Hello, world!");
    try engine.loop.run(.once);
    try testing.expect(test_actor.underlying.hello_world_received);
}
