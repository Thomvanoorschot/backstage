const std = @import("std");

pub const ActorID = struct {
    actor_type: []const u8,
    key: []const u8,

    const Self = @This();

    pub fn init(actor_type: []const u8, key: []const u8) Self {
        return Self{
            .actor_type = actor_type,
            .key = key,
        };
    }

    // TODO Maybe remove this?
    pub fn initOwned(allocator: std.mem.Allocator, actor_type: []const u8, key: []const u8) !Self {
        return Self{
            .actor_type = try allocator.dupe(u8, actor_type),
            .key = try allocator.dupe(u8, key),
        };
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.actor_type);
        allocator.free(self.key);
    }

    pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}::{s}", .{ self.actor_type, self.key });
    }

    pub fn fromString(allocator: std.mem.Allocator, id_str: []const u8) !Self {
        var parts = std.mem.splitSequence(u8, id_str, "::");

        const actor_type = parts.next() orelse return error.InvalidFormat;
        const key = parts.next() orelse return error.InvalidFormat;

        if (parts.next() != null) return error.InvalidFormat;

        return initOwned(allocator, actor_type, key);
    }

    pub fn eql(self: Self, other: Self) bool {
        return std.mem.eql(u8, self.actor_type, other.actor_type) and
            std.mem.eql(u8, self.key, other.key);
    }

    pub fn hash(self: Self) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.actor_type);
        hasher.update("::");
        hasher.update(self.key);
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
