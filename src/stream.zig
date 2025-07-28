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

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *Engine,
        id: []const u8,
        comptime PayloadType: type,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .handle_ptr = try StreamHandle(PayloadType).init(
                allocator,
                id,
                self,
                onNext,
                subscribe,
            ),
            .subscribers = std.ArrayList(Subscriber).init(allocator),
            .engine = engine,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.subscribers.deinit();
        // self.allocator.destroy(self.handle_ptr);
    }

    pub fn onNext(self_: *anyopaque, payload: []const u8) !void {
        const self = unsafeAnyOpaqueCast(Self, self_);

        for (self.subscribers.items) |subscription| {
            try engine_internal.enqueueMessage(
                self.engine,
                null,
                subscription.actor_id,
                .method_call,
                MethodCall{
                    .method_id = subscription.method_id,
                    .params = payload,
                },
            );
        }
        // const encoded = try encodeStreamMessage(T, item, self.provider.engine.allocator);
        // defer self.provider.engine.allocator.free(encoded);

        // try self.provider.engine.publishToStream(self.stream_id, self.namespace, encoded);
    }

    pub fn subscribe(self_: *anyopaque, subscriber: Subscriber) !void {
        const self = unsafeAnyOpaqueCast(Self, self_);
        try self.subscribers.append(subscriber);
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
        on_next_fn: *const fn (*anyopaque, []const u8) anyerror!void,
        subscribe_fn: *const fn (*anyopaque, Subscriber) anyerror!void,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            id: []const u8,
            ptr: *anyopaque,
            on_next_fn: *const fn (self: *anyopaque, item: PayloadType) anyerror!void,
            subscribe_fn: *const fn (self: *anyopaque, subscriber: Subscriber) anyerror!void,
        ) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .id = id,
                .stream_ptr = ptr,
                .on_next_fn = on_next_fn,
                .subscribe_fn = subscribe_fn,
            };
            return self;
        }

        pub fn onNext(self: *Self, payload: PayloadType) !void {
            _ = payload;
            // TODO Encode payload
            try self.on_next_fn(self.stream_ptr, "TODO");
        }

        pub fn subscribe(self: *Self, subscriber: Subscriber) !void {
            try self.subscribe_fn(self.stream_ptr, subscriber);
        }
    };
}
