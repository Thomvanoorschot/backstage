const backstage = @import("backstage");
const std = @import("std");
const testing = std.testing;

const Engine = backstage.Engine;
const Context = backstage.Context;
const Envelope = backstage.Envelope;

const SenderActor = struct {
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

    pub fn receive(self: *Self, envelope: Envelope) !void {
        try self.ctx.send("receiver_actor", envelope.message);
    }

    pub fn deinit(_: *Self) !void {}
};

const ReceiverActor = struct {
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

    pub fn receive(self: *Self, envelope: Envelope) !void {
        if (std.mem.eql(u8, envelope.message, "Hello, world!")) {
            self.hello_world_received = true;
            std.log.info("{s}", .{envelope.message});
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

    _ = try engine.spawnActor(SenderActor, .{
        .id = "sender_actor",
    });
    const receiver_actor = try engine.spawnActor(ReceiverActor, .{ // TODO: why is this not working?
        .id = "receiver_actor",
    });
    try engine.send("sender_actor", "Hello, world!");
    try engine.loop.run(.once);
    
    try testing.expect(receiver_actor.hello_world_received);
}
