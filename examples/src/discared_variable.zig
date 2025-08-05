const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;
const DiscaredVariableActorProxy = @import("generated/discared_variable_actor_proxy.gen.zig").DiscaredVariableActorProxy;

// @generate-proxy
pub const DiscaredVariableActor = struct {
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

    pub fn handleDiscaredVariable(_: *Self, _: []const u8, _: u64, used_param: u64) !void {
        std.log.info("A number with no meaning whatsoever: {}", .{used_param});
    }

    pub fn deinit(_: *Self) !void {}
};

// These will be used in another test
pub const FirstExportedVariable = struct {
    number: u64,
};

pub const SecondExportedVariable = struct {
    number: u64,
};

test "Discared variable" {
    testing.log_level = .info;
    var engine = try backstage.Engine.init(std.testing.allocator);
    defer engine.deinit();

    const test_actor = try engine.getActor(DiscaredVariableActorProxy, "test_actor");
    try test_actor.handleDiscaredVariable("Hello, world!", 1, 42);
    try engine.loop.run(.once);
}
