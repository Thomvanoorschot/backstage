const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const newSubscriber = backstage.newSubscriber;
const PubActorProxy = @import("generated/pub_actor_proxy.gen.zig").PubActorProxy;
const SubOneActorProxy = @import("generated/sub_one_actor_proxy.gen.zig").SubOneActorProxy;
const SubTwoActorProxy = @import("generated/sub_two_actor_proxy.gen.zig").SubTwoActorProxy;

// @generate-proxy
pub const PubActor = struct {
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

    pub fn publish(self: *Self, message: []const u8) !void {
        const stream = try self.ctx.getStream([]const u8, "test");
        try stream.next(message);
    }

    pub fn deinit(_: *Self) !void {}
};

// @generate-proxy
pub const SubOneActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    message_received: bool,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
            .message_received = false,
        };
        return self;
    }

    pub fn subscribe(self: *Self) !void {
        const stream = try self.ctx.getStream([]const u8, "test");
        try stream.subscribe(
            newSubscriber("sub_one_actor", SubOneActorProxy.Method.handleMessage),
        );
    }

    pub fn handleMessage(self: *Self, message: []const u8) !void {
        std.log.info("Sub one received message: {s}", .{message});
        self.message_received = true;
    }

    pub fn deinit(_: *Self) !void {}
};
// @generate-proxy
pub const SubTwoActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    message_received: bool,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
            .message_received = false,
        };
        return self;
    }

    pub fn subscribe(self: *Self) !void {
        const stream = try self.ctx.getStream([]const u8, "test");
        try stream.subscribe(
            newSubscriber("sub_two_actor", SubTwoActorProxy.Method.handleMessage),
        );
    }

    pub fn handleMessage(self: *Self, message: []const u8) !void {
        std.log.info("Sub two received message: {s}", .{message});
        self.message_received = true;
    }

    pub fn deinit(_: *Self) !void {}
};

test "Pub sub" {
    testing.log_level = .info;
    var engine = try backstage.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const sub_one_actor = try engine.getActor(SubOneActorProxy, "sub_one_actor");
    const sub_two_actor = try engine.getActor(SubTwoActorProxy, "sub_two_actor");
    const pub_actor = try engine.getActor(PubActorProxy, "pub_actor");
    try sub_one_actor.subscribe();
    try sub_two_actor.subscribe();
    try pub_actor.publish("Hello, world!");
    try engine.loop.run(.once);
    try testing.expect(sub_one_actor.underlying.message_received);
    try testing.expect(sub_two_actor.underlying.message_received);
}
