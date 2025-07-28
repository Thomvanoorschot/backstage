const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const PubActorProxy = @import("generated/pub_actor_proxy.gen.zig").PubActorProxy;
const SubActorProxy = @import("generated/sub_actor_proxy.gen.zig").SubActorProxy;

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
        try stream.onNext(message);
    }

    pub fn deinit(_: *Self) !void {}
};

// @generate-proxy
pub const SubActor = struct {
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

    pub fn subscribe(self: *Self) !void {
        const stream = try self.ctx.getStream([]const u8, "test");
        //TODO The way we have to set the subscriber sucks, but it's a temporary solution
        try stream.subscribe(.{
            .actor_id = "sub_actor",
            .method_id = 1,
        });
    }

    pub fn handleMessage(_: *Self, message: []const u8) !void {
        std.log.info("Received message: {s}", .{message});
    }

    pub fn deinit(_: *Self) !void {}
};

test "Pub sub" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const sub_actor = try engine.getActor(SubActorProxy, "sub_actor");
    const pub_actor = try engine.getActor(PubActorProxy, "pub_actor");
    try sub_actor.subscribe();
    try pub_actor.publish("Hello, world!");
    try engine.loop.run(.once);
}
