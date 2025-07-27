const strm_provider = @import("stream_provider.zig");

const StreamProvider = strm_provider.StreamProvider;

pub fn Stream(comptime T: type) type {
    return struct {
        stream_id: []const u8,
        namespace: []const u8,
        provider: *StreamProvider,
        
        const Self = @This();
        
        pub fn onNext(self: *Self, item: T) !void {
            // Serialize and send to all subscribers
            const encoded = try encodeStreamMessage(T, item, self.provider.engine.allocator);
            defer self.provider.engine.allocator.free(encoded);
            
            try self.provider.engine.publishToStream(self.stream_id, self.namespace, encoded);
        }
        
        pub fn subscribe(self: *Self, handler: StreamHandler(T)) !StreamSubscriptionHandle(T) {
            return try self.provider.engine.subscribeToStream(T, self.stream_id, self.namespace, handler);
        }
    };
}