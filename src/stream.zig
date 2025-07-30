const std = @import("std");
const type_utils = @import("type_utils.zig");
const engine_internal = @import("engine_internal.zig");
const envlp = @import("envelope.zig");
const eng = @import("engine.zig");
const zbor = @import("zbor");

const Engine = eng.Engine;
const MethodCall = envlp.MethodCall;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const stringify = zbor.stringify;

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
                var str = std.ArrayList(u8).init(stream.allocator);
                defer str.deinit();
                try stringify(payload, .{}, str.writer());

                for (stream.subscribers.items) |subscription| {
                    try engine_internal.enqueueMessage(
                        stream.engine,
                        null,
                        subscription.actor_id,
                        .method_call,
                        MethodCall{
                            .method_id = subscription.method_id,
                            .params = str.items,
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
pub fn newSubscriber(actor_id: []const u8, comptime method: anytype) Subscriber {
    const method_id = comptime switch (@typeInfo(@TypeOf(method))) {
        .@"enum" => |enum_info| blk: {
            if (enum_info.tag_type != u32) {
                @compileError("Enum must have u32 underlying type, got " ++ @typeName(enum_info.tag_type));
            }
            break :blk @intFromEnum(method);
        },
        .@"int" => blk: {
            if (@TypeOf(method) != u32) {
                @compileError("Integer must be u32, got " ++ @typeName(@TypeOf(method)));
            }
            break :blk method;
        },
        else => @compileError("Expected enum(u32) or u32, got " ++ @typeName(@TypeOf(method))),
    };

    return Subscriber{
        .actor_id = actor_id,
        .method_id = method_id,
    };
}

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
