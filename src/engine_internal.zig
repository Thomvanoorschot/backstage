const std = @import("std");
const engine = @import("engine.zig");
const envlp = @import("envelope.zig");
const type_utils = @import("type_utils.zig");
const actr = @import("actor.zig");

const Engine = engine.Engine;
const Envelope = envlp.Envelope;
const MessageType = envlp.MessageType;
const ActorInterface = actr.ActorInterface;

pub fn enqueueMessage(
    self: *Engine,
    sender_id: ?[]const u8,
    target_id: []const u8,
    message_type: MessageType,
    message: anytype,
) !void {
    const actor = self.registry.getByID(target_id);
    if (actor) |a| {
        const T = @TypeOf(message);
        switch (@typeInfo(T)) {
            .pointer => |ptr| {
                if (ptr.child != u8 and @typeInfo(ptr.child) != .array) {
                    @compileError("Only []const u8 or string literals supported");
                }
                if (@typeInfo(ptr.child) == .array) {
                    if (@typeInfo(ptr.child).array.child != u8) {
                        @compileError("Only []const u8 or string literals supported");
                    }
                }
            },
            .@"struct" => if (!comptime type_utils.hasMethod(T, "encode")) @compileError("Struct must have encode() method"),
            else => @compileError("Message must be []const u8, a string literal or struct with an encode() method"),
        }

        const message_data = if (@typeInfo(T) == .@"struct") blk: {
            break :blk try message.encode(self.allocator);
        } else blk: {
            break :blk message;
        };
        defer if (@typeInfo(T) == .@"struct") self.allocator.free(message_data);

        const envelope = Envelope.init(sender_id, message_type, message_data);
        try a.inbox.enqueue(envelope);
        try a.notifyMessageHandler();
    } else {
        std.log.warn("Actor not found: {s}", .{target_id});
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
