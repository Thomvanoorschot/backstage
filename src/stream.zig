const std = @import("std");
const type_utils = @import("type_utils.zig");
const engine_internal = @import("engine_internal.zig");
const envlp = @import("envelope.zig");
const eng = @import("engine.zig");

const Engine = eng.Engine;
const MethodCall = envlp.MethodCall;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;

pub const Stream = struct {
    allocator: std.mem.Allocator,
    handle_ptr: *anyopaque,
    subscribers: std.ArrayList(Subscriber),
    engine: *Engine,
    deinit_impl_fn: *const fn (std.mem.Allocator, *anyopaque) void,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *Engine,
        id: []const u8,
        comptime PayloadType: type,
    ) !*Self {
        const self = try allocator.create(Self);

        const StreamImpl = struct {
            pub fn onNext(self_: *anyopaque, payload: PayloadType) !void {
                const stream = unsafeAnyOpaqueCast(Stream, self_);

                // TODO Change the way payloads are encoded and handled
                const payload_bytes = if (PayloadType == []const u8)
                    payload
                else
                    @as([]const u8, @ptrCast(&payload))[0..@sizeOf(PayloadType)];

                // TODO Move this temporary solution to a more appropriate place
                var params_json = std.ArrayList(u8).init(stream.allocator);
                defer params_json.deinit();
                try std.json.stringify(.{ .message = payload_bytes }, .{}, params_json.writer());
                const params_str = try params_json.toOwnedSlice();
                defer stream.allocator.free(params_str);

                for (stream.subscribers.items) |subscription| {
                    try engine_internal.enqueueMessage(
                        stream.engine,
                        null,
                        subscription.actor_id,
                        .method_call,
                        MethodCall{
                            .method_id = subscription.method_id,
                            .params = params_str,
                        },
                    );
                }
            }

            pub fn subscribe(self_: *anyopaque, subscriber: Subscriber) !void {
                const stream = unsafeAnyOpaqueCast(Stream, self_);
                try stream.subscribers.append(subscriber);
            }

            pub fn deinit(alloc: std.mem.Allocator, handle_ptr: *anyopaque) void {
                const handle = unsafeAnyOpaqueCast(StreamHandle(PayloadType), handle_ptr);
                alloc.destroy(handle);
            }
        };

        const handle = try allocator.create(StreamHandle(PayloadType));
        handle.* = try StreamHandle(PayloadType).init(
            id,
            self,
            StreamImpl.onNext,
            StreamImpl.subscribe,
        );

        self.* = .{
            .allocator = allocator,
            .handle_ptr = handle,
            .subscribers = std.ArrayList(Subscriber).init(allocator),
            .engine = engine,
            .deinit_impl_fn = StreamImpl.deinit,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.subscribers.deinit();
        self.deinit_impl_fn(self.allocator, self.handle_ptr);
    }
};

const Subscriber = struct {
    actor_id: []const u8,
    method_id: u32,
};

pub fn StreamHandle(comptime PayloadType: type) type {
    return struct {
        id: []const u8,
        stream_ptr: *anyopaque,
        next_fn: *const fn (*anyopaque, PayloadType) anyerror!void,
        subscribe_fn: *const fn (*anyopaque, Subscriber) anyerror!void,

        const Self = @This();

        pub fn init(
            id: []const u8,
            ptr: *anyopaque,
            on_next_fn: *const fn (self: *anyopaque, item: PayloadType) anyerror!void,
            subscribe_fn: *const fn (self: *anyopaque, subscriber: Subscriber) anyerror!void,
        ) !Self {
            return .{
                .id = id,
                .stream_ptr = ptr,
                .next_fn = on_next_fn,
                .subscribe_fn = subscribe_fn,
            };
        }

        pub fn next(self: *Self, payload: PayloadType) !void {
            try self.next_fn(self.stream_ptr, payload);
        }

        pub fn subscribe(self: *Self, subscriber: Subscriber) !void {
            try self.subscribe_fn(self.stream_ptr, subscriber);
        }
    };
}
