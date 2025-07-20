const std = @import("std");

pub const ActorID = struct {
    actor_type: []const u8,
    unique_id: []const u8,
    engine_id: []const u8,

    const Self = @This();

    pub fn init(actor_type: []const u8, unique_id: []const u8, engine_id: []const u8) Self {
        return Self{
            .actor_type = actor_type,
            .unique_id = unique_id,
            .engine_id = engine_id,
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, actor_type: []const u8, unique_id: []const u8, engine_id: []const u8) !Self {
        return Self{
            .actor_type = try allocator.dupe(u8, actor_type),
            .unique_id = try allocator.dupe(u8, unique_id),
            .engine_id = try allocator.dupe(u8, engine_id),
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.actor_type);
        allocator.free(self.unique_id);
        allocator.free(self.engine_id);
    }

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}::{s}::{s}", .{ self.engine_id, self.actor_type, self.unique_id });
    }

    pub fn fromString(allocator: std.mem.Allocator, id_str: []const u8) !Self {
        var parts = std.mem.splitSequence(u8, id_str, "::");

        const engine_id = parts.next() orelse return error.InvalidFormat;
        const actor_type = parts.next() orelse return error.InvalidFormat;
        const unique_id = parts.next() orelse return error.InvalidFormat;

        if (parts.next() != null) return error.InvalidFormat;

        return initOwned(allocator, actor_type, unique_id, engine_id);
    }

    pub fn eql(self: Self, other: Self) bool {
        return std.mem.eql(u8, self.actor_type, other.actor_type) and
            std.mem.eql(u8, self.unique_id, other.unique_id) and
            std.mem.eql(u8, self.engine_id, other.engine_id);
    }

    pub fn hash(self: Self) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.engine_id);
        hasher.update("::");
        hasher.update(self.actor_type);
        hasher.update("::");
        hasher.update(self.unique_id);
        return hasher.final();
    }

    pub const HashContext = struct {
        pub fn hash(_: @This(), key: ActorID) u64 {
            return key.hash();
        }

        pub fn eql(_: @This(), a: ActorID, b: ActorID) bool {
            return a.eql(b);
        }
    };
};

pub fn ActorHashMap(comptime V: type) type {
    return std.HashMap(ActorID, V, ActorID.HashContext, std.hash_map.default_max_load_percentage);
}
