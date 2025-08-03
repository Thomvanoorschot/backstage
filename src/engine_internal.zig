const std = @import("std");
const engine = @import("engine.zig");
const envlp = @import("envelope.zig");
const type_utils = @import("type_utils.zig");
const actr = @import("actor.zig");

const Engine = engine.Engine;
const Envelope = envlp.Envelope;
const MessageType = envlp.MessageType;
const ActorInterface = actr.ActorInterface;
const MethodCall = envlp.MethodCall;

pub fn enqueueMethodCall(
    self: *Engine,
    sender_id: ?[]const u8,
    target_id: []const u8,
    method_call: MethodCall,
) !void {
    const actor = self.registry.getByID(target_id);
    if (actor) |a| {
        const method_call_bytes = try method_call.encode(self.allocator);
        defer self.allocator.free(method_call_bytes);

        const envelope = Envelope.init(
            sender_id,
            .method_call,
            method_call_bytes,
        );
        try a.inbox.enqueue(envelope);
        try a.notifyMessageHandler();
    } else {
        std.log.warn("Actor not found: {s}", .{target_id});
    }
}

pub fn enqueuePoisonPill(self: *Engine, target_id: []const u8) !void {
    const actor = self.registry.getByID(target_id);
    if (actor) |a| {
        try a.inbox.enqueue(Envelope.init(null, .poison_pill, ""));
        try a.notifyMessageHandler();
    }
}

pub fn deinitActorByID(self: *Engine, id: []const u8) void {
    const actor = self.registry.fetchRemove(id);
    if (!actor) {
        std.log.warn("Actor not found: {s}", .{id});
        return;
    }
    deinitActor(self, actor.*);
}

pub fn deinitActorByReference(self: *Engine, actor: *ActorInterface) void {
    if (!self.registry.remove(actor.ctx.actor_id)) {
        std.log.warn("Actor not found: {s}", .{actor.ctx.actor_id});
        return;
    }
    actor.deinit();
    removeFromInspector(self, actor);
    self.allocator.destroy(actor);
}

fn deinitActor(self: *Engine, actor: *ActorInterface) void {
    actor.deinit();
    removeFromInspector(self, actor);
    self.allocator.destroy(actor);
}

fn removeFromInspector(self: *Engine, actor: *ActorInterface) void {
    if (self.inspector != null) {
        self.inspector.?.actorTerminated(actor) catch |err| {
            std.log.warn("Tried to update inspector but failed: {s}", .{@errorName(err)});
        };
    }
}
