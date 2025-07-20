const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;

// @generate-proxy
const LazyActor = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    amount: u64 = 0,
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
        };
        return self;
    }
    pub fn deinit(_: *Self) !void {}

    pub fn addAmount(self: *Self, amount: u64) !void {
        self.amount += amount;
    }

};

test "Lazy actor" {
    testing.log_level = .info;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try backstage.Engine.init(allocator);
    defer engine.deinit();

    const test_actor = try engine.spawnActor(LazyActor, .{
        .id = "test_actor",
    });
    try test_actor.addAmount(10);
    try engine.loop.run(.once);
    try testing.expect(test_actor.amount == 10);
}
