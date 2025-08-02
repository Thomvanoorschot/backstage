const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const PoisonPillActorProxy = @import("generated/poison_pill_actor_proxy.gen.zig").PoisonPillActorProxy;

// @generate-proxy
pub const PoisonPillActor = struct {
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

    pub fn swallowPoisonPill(self: *Self) !void {
        try self.ctx.poisonPill();
    }

    pub fn deinit(_: *Self) !void {}
};

test "Poison pill" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const test_actor = try engine.getActor(PoisonPillActorProxy, "test_actor");
    try testing.expect(engine.registry.actorsIDMap.count() == 1);
    try test_actor.swallowPoisonPill();
    try engine.loop.run(.once);
    try testing.expect(engine.registry.actorsIDMap.count() == 0);
}
