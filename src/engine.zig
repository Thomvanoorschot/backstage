const reg = @import("registry.zig");
const act = @import("actor.zig");
const envlp = @import("envelope.zig");
const actor_ctx = @import("context.zig");
const std = @import("std");
const req = @import("request.zig");
const xev = @import("xev");

const Allocator = std.mem.Allocator;
const Registry = reg.Registry;
const ActorInterface = act.ActorInterface;
const Context = actor_ctx.Context;
const Request = req.Request;
const Envelope = envlp.Envelope;

pub const SpawnActorOptions = struct {
    id: []const u8,
    capacity: usize = 1024,
};

pub const Engine = struct {
    registry: Registry,
    allocator: Allocator,
    loop: xev.Loop,
    thread_pool: xev.ThreadPool,
    const Self = @This();
    pub fn init(allocator: Allocator) !Self {
        var thread_pool = xev.ThreadPool.init(.{});

        return .{
            .registry = Registry.init(allocator),
            .allocator = allocator,
            .thread_pool = thread_pool,
            .loop = try xev.Loop.init(.{
                .thread_pool = &thread_pool,
            }),
        };
    }

    pub fn run(self: *Self) !void {
        try self.loop.run(.until_done);
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
        self.thread_pool.deinit();
        self.thread_pool.shutdown();
        self.loop.deinit();
    }

    pub fn spawnActor(self: *Self, comptime ActorType: type, comptime MsgType: type, options: SpawnActorOptions) !*ActorInterface {
        const actor = self.registry.getByID(options.id);
        if (actor) |a| {
            return a;
        }
        const ctx = try Context.init(self.allocator, self, options.id);
        const actor_interface = try ActorInterface.create(self.allocator, ctx, ActorType, Envelope(MsgType), options.capacity);
        errdefer actor_interface.deinit() catch unreachable;

        try self.registry.add(options.id, Envelope(MsgType), actor_interface);
        return actor_interface;
    }

    pub fn send(self: *Self, sender: ?*ActorInterface, id: []const u8, message: anytype) !void {
        const actor = self.registry.getByID(id);
        if (actor) |a| {
            try a.send(sender, message);
        } else {
            return error.ActorNotFound;
        }
    }
    pub fn broadcast(self: *Self, sender: ?*const ActorInterface, message: anytype) !void {
        const actor = self.registry.getByMessageType(message);
        if (actor) |a| {
            try a.send(sender, message);
        }
    }

    pub fn request(self: *Engine, sender: ?*const ActorInterface, id: []const u8, original_message: anytype, comptime ResultType: type) !ResultType {
        // Needs to be reimplemented
        _ = sender;
        _ = id;
        _ = original_message;
        _ = self;
    }
};
