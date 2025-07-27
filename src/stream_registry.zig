const std = @import("std");

const StreamSubscription = struct {
    actor_id: []const u8,
    method_id: u32,
};

const StreamSubscribeRequest = struct {
    stream_id: []const u8,
    actor_id: []const u8,
    method_id: u32,
};

pub const StreamRegistry = struct {
    allocator: std.mem.Allocator,
    streams: std.StringHashMap(std.ArrayList(StreamSubscription)),

    pub fn init(allocator: std.mem.Allocator) StreamRegistry {
        return .{
            .allocator = allocator,
            .streams = std.StringHashMap(std.ArrayList(StreamSubscription)).init(allocator),
        };
    }

    pub fn deinit(self: *StreamRegistry) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |subscription| {
                self.allocator.free(subscription.actor_id);
            }
            entry.value_ptr.deinit();
        }
        self.streams.deinit();
    }

    pub fn subscribe(self: *StreamRegistry, request: StreamSubscribeRequest) !void {
        var subscriptions = self.streams.getPtr(request.stream_id);
        if (subscriptions == null) {
            try self.streams.put(request.stream_id, std.ArrayList(StreamSubscription).init(self.allocator));
            subscriptions = self.streams.getPtr(request.stream_id);
        } else {
            self.allocator.free(request.stream_id);
        }

        // Check if already subscribed
        for (subscriptions.?.items) |existing_subscription| {
            if (std.mem.eql(u8, existing_subscription.actor_id, request.actor_id) and existing_subscription.method_id == request.method_id) return;
        }

        const owned_actor_id = try self.allocator.dupe(u8, request.actor_id);
        try subscriptions.?.append(.{
            .actor_id = owned_actor_id,
            .method_id = request.method_id,
        });
    }

    pub fn getSubscriptions(self: *StreamRegistry, stream_id: []const u8) []const StreamSubscription {
        if (self.streams.get(stream_id)) |subscriptions| {
            return subscriptions.items;
        }
        return &[_]StreamSubscription{};
    }
};
