const std = @import("std");
const strm = @import("stream.zig");

const Stream = strm.Stream;

pub const StreamRegistry = struct {
    allocator: std.mem.Allocator,
    streams: std.StringHashMap(*Stream),

    pub fn init(allocator: std.mem.Allocator) StreamRegistry {
        return .{
            .allocator = allocator,
            .streams = std.StringHashMap(*Stream).init(allocator),
        };
    }

    pub fn deinit(self: *StreamRegistry) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
    }
    pub fn add(self: *StreamRegistry, stream_id: []const u8, stream: *Stream) !void {
        const owned_id = try self.allocator.dupe(u8, stream_id);
        try self.streams.put(owned_id, stream);
    }

    pub fn getByID(self: *StreamRegistry, stream_id: []const u8) ?*Stream {
        return self.streams.get(stream_id);
    }
};
