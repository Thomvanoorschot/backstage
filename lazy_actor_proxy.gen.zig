// AUTO-GENERATED ACTOR PROXY. DO NOT EDIT BY HAND.
// Generated proxy for LazyActor

const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const LazyActor = @import("lazy_actor.zig").LazyActor;

pub const LazyActorProxy = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: LazyActor,
    
    const Self = @This();
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        return Self{ .underlying = LazyActor.init(ctx, allocator) };
    }

    pub fn deinit(self: *Self) !void {
        self.underlying.deinit();
    }

    pub fn addAmount(self: *Self, amount: u64) !void {
        return self.underlying.addAmount(amount);
    }

};
