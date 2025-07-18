const reg = @import("registry.zig");
const act = @import("actor.zig");
const actor_ctx = @import("context.zig");
const std = @import("std");
const xev = @import("xev");
const envlp = @import("envelope.zig");
const type_utils = @import("type_utils.zig");
const build_options = @import("build_options");
const ispct = @import("inspector/inspector.zig");
const zignite = if (build_options.enable_inspector) @import("zignite") else {};
const internal = @import("engine_internal.zig");

const Allocator = std.mem.Allocator;
const Registry = reg.Registry;
const ActorInterface = act.ActorInterface;
const Context = actor_ctx.Context;
const MessageType = envlp.MessageType;
const Envelope = envlp.Envelope;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const Inspector = ispct.Inspector;

pub const ActorOptions = struct {
    id: []const u8,
    capacity: usize = 1024,
};

pub const Engine = struct {
    registry: Registry,
    allocator: Allocator,
    loop: xev.Loop,
    inspector: ?*Inspector = null,
    const Self = @This();
    pub fn init(allocator: Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .loop = try xev.Loop.init(.{}),
        };
        if (build_options.enable_inspector) {
            self.inspector = try Inspector.init(allocator);
        }
        return self;
    }

    pub fn run(self: *Self) !void {
        try self.loop.run(.until_done);
    }

    pub fn deinit(self: *Self) void {
        if (self.inspector != null) {
            self.inspector.?.deinit();
        }
        self.loop.deinit();
        var it = self.registry.actorsIDMap.iterator();
        while (it.next()) |entry| {
            // We are calling the deinit function for the actor implementation here.
            // Normally the deinit function is called on the actor interface itself,
            // but the engine itself is being deinitialized.
            entry.value_ptr.*.deinitFnPtr(entry.value_ptr.*.impl) catch |err| {
                std.log.err("Failed to deinit actor: {s}", .{@errorName(err)});
            };
            internal.deinitActorByReference(self, entry.value_ptr.*);
        }
        self.registry.deinit();
    }

    pub fn spawnActor(self: *Self, comptime ActorType: type, options: ActorOptions) !*ActorType {
        const actor = self.registry.getByID(options.id);
        if (actor) |a| {
            return unsafeAnyOpaqueCast(ActorType, a.impl);
        }
        const actor_interface = try ActorInterface.init(
            self.allocator,
            self,
            ActorType,
            options,
            self.inspector,
        );
        errdefer actor_interface.deinitFnPtr(actor_interface.impl) catch |err| {
            std.log.err("Failed to deinit actor: {s}", .{@errorName(err)});
        };

        try self.registry.add(options.id, actor_interface);
        if (self.inspector != null) {
            self.inspector.?.actorSpawned(actor_interface) catch |err| {
                std.log.warn("Tried to update inspector but failed: {s}", .{@errorName(err)});
            };
        }
        return unsafeAnyOpaqueCast(ActorType, actor_interface.impl);
    }

    pub fn send(
        self: *Self,
        target_id: []const u8,
        message: anytype,
    ) !void {
        return internal.enqueueMessage(
            self,
            null,
            target_id,
            .send,
            message,
        );
    }
    pub fn publish(
        self: *Self,
        target_id: []const u8,
        message: anytype,
    ) !void {
        return internal.enqueueMessage(
            self,
            null,
            target_id,
            .publish,
            message,
        );
    }

    pub fn subscribeToActorTopic(
        self: *Self,
        sender_id: []const u8,
        target_id: []const u8,
        topic: []const u8,
    ) !void {
        return internal.enqueueMessage(
            self,
            sender_id,
            target_id,
            .subscribe,
            topic,
        );
    }

    pub fn unsubscribeFromActorTopic(
        self: *Self,
        sender_id: []const u8,
        target_id: []const u8,
        topic: []const u8,
    ) !void {
        return internal.enqueueMessage(
            self,
            sender_id,
            target_id,
            .unsubscribe,
            topic,
        );
    }

    pub fn poisonPill(self: *Self, target_id: []const u8) !void {
        return internal.enqueueMessage(
            self,
            null,
            target_id,
            .poison_pill,
            "",
        );
    }
};
