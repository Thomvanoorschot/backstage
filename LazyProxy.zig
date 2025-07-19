// AUTO-GENERATED ACTOR PROXY. DO NOT EDIT BY HAND.
// Generated proxy for LazyActor

const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const Envelope = backstage.Envelope;

pub const LazyActorProxy = struct {
    const Self = @This();
    
    ctx: *Context,
    allocator: std.mem.Allocator,
    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        _ = ctx;
        _ = allocator;
        // TODO: implement
    }

    pub fn receive(self: *Self, envelope: Envelope) !void {
        _ = self;
        _ = envelope;
        // TODO: implement
    }

    pub fn deinit(_: *Self) !void {
        // TODO: implement
    }

};
