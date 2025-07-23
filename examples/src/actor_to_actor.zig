const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const ReceiverActorProxy = @import("generated/receiver_actor_proxy.gen.zig").ReceiverActorProxy;
const SenderActorProxy = @import("generated/sender_actor_proxy.gen.zig").SenderActorProxy;

// @generate-proxy
pub const SenderActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }

    pub fn sendMessage(self: *Self, message: []const u8) !void {
        const receiver_actor = try self.ctx.getActor(ReceiverActorProxy, "receiver_actor");
        try receiver_actor.receiveMessage(message);
    }

    pub fn deinit(_: *Self) !void {}
};

// @generate-proxy
pub const ReceiverActor = struct {
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

    pub fn receiveMessage(self: *Self, message: []const u8) !void {
        if (std.mem.eql(u8, message, "Hello, world!")) {
            self.hello_world_received = true;
            std.log.info("{s}", .{message});
        }
    }

    pub fn deinit(_: *Self) !void {}
};

test "Actor to actor" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const sender_actor = try engine.getActor(SenderActorProxy, "sender_actor");
    const receiver_actor = try engine.getActor(ReceiverActorProxy, "receiver_actor");
    try sender_actor.sendMessage("Hello, world!");
    try engine.loop.run(.once);

    try testing.expect(receiver_actor.underlying.hello_world_received);
}
