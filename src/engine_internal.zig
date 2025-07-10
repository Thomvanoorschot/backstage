const std = @import("std");
const engine = @import("engine.zig");
const envlp = @import("envelope.zig");
const type_utils = @import("type_utils.zig");

const Self = engine.Engine;
const Envelope = envlp.Envelope;
const MessageType = envlp.MessageType;

pub fn enqueueMessage(
    self: *Self,
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
