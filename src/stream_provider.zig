const Engine = @import("engine.zig");
const Stream = @import("stream.zig");

pub const StreamProvider = struct {
    name: []const u8,
    engine: *Engine,
    
    pub fn getStream(self: *StreamProvider, comptime T: type, stream_id: []const u8, namespace: ?[]const u8) Stream(T) {
        return Stream(T){
            .stream_id = stream_id,
            .namespace = namespace orelse "default",
            .provider = self,
        };
    }
};