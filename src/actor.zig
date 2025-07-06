const std = @import("std");
const inbox = @import("inbox.zig");
const eng = @import("engine.zig");
const ctxt = @import("context.zig");
const envlp = @import("envelope.zig");
const xev = @import("xev");
const type_utils = @import("type_utils.zig");
const ispct = @import("inspector/inspector.zig");

const Allocator = std.mem.Allocator;
const Inbox = inbox.Inbox;
const Engine = eng.Engine;
const Context = ctxt.Context;
const Envelope = envlp.Envelope;
const ActorOptions = eng.ActorOptions;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const Inspector = ispct.Inspector;

// TODO This is a bit of a hack, storing it on the stack causes a segfault when the actor is destroyed
var cancel_completion: xev.Completion = undefined;

pub const ActorInterface = struct {
    allocator: Allocator,
    impl: *anyopaque,
    inbox: *Inbox,
    ctx: *Context,
    completion: xev.Completion = undefined,
    wakeup: xev.Async,
    wakeup_completion: xev.Completion = undefined,
    arena_state: std.heap.ArenaAllocator,
    is_shutting_down: bool = false,
    inspector: ?*Inspector,
    deinitFnPtr: *const fn (ptr: *anyopaque) anyerror!void,
    receiveFnPtr: *const fn (ptr: *anyopaque, envelope: Envelope) anyerror!void,
    actor_type_name: []const u8,

    const Self = @This();

    pub fn create(
        allocator: Allocator,
        engine: *Engine,
        comptime ActorType: type,
        options: ActorOptions,
        inspector: ?*Inspector,
    ) !*Self {
        const self = try allocator.create(Self);
        var wakeup_h = try xev.Async.init();
        errdefer wakeup_h.deinit();
        self.* = .{
            .allocator = allocator,
            .arena_state = std.heap.ArenaAllocator.init(allocator),
            .deinitFnPtr = makeTypeErasedDeinitFn(ActorType),
            .receiveFnPtr = makeTypeErasedReceiveFn(ActorType),
            .inbox = undefined,
            .ctx = undefined,
            .impl = undefined,
            .inspector = inspector,
            .actor_type_name = blk: {
                const full_name = @typeName(ActorType);
                if (std.mem.lastIndexOf(u8, full_name, ".")) |last_dot_index| {
                    break :blk full_name[last_dot_index + 1 ..];
                } else {
                    break :blk full_name;
                }
            },
            .wakeup = wakeup_h,
        };
        errdefer self.arena_state.deinit();
        const ctx = try Context.init(
            self.arena_state.allocator(),
            engine,
            self,
            options.id,
        );
        self.ctx = ctx;
        self.impl = try ActorType.init(ctx, self.arena_state.allocator());
        self.inbox = try Inbox.init(self.allocator, options.capacity);

        self.wakeup.wait(
            &self.ctx.engine.loop,
            &self.wakeup_completion,
            Self,
            self,
            handleMessage,
        );
        try self.wakeup.notify();

        return self;
    }

    pub fn notifyMessageHandler(self: *Self) !void {
        try self.wakeup.notify();
    }

    fn handleMessage(
        self_: ?*Self,
        _: *xev.Loop,
        _: *xev.Completion,
        r: xev.Async.WaitError!void,
    ) xev.CallbackAction {
        _ = r catch |err| {
            std.log.err("error in wakeup err={}", .{err});
            return .rearm;
        };

        const self = self_.?;

        // Process all available messages in a loop
        while (self.inbox.dequeue() catch null) |envelope| {
            if (self.inspector) |inspector| {
                inspector.envelopeReceived(self, envelope) catch |err| {
                    std.log.warn("Tried to update inspector but failed: {s}", .{@errorName(err)});
                };
            }

            switch (envelope.message_type) {
                .send => {
                    self.receiveFnPtr(self.impl, envelope) catch |err| {
                        std.log.err("Tried to receive message but failed: {s}", .{@errorName(err)});
                    };
                },
                .publish => {
                    self.receiveFnPtr(self.impl, envelope) catch |err| {
                        std.log.err("Tried to receive message but failed: {s}", .{@errorName(err)});
                    };
                },
                .subscribe => {
                    self.addSubscriber(envelope) catch |err| {
                        std.log.err("Tried to put topic subscription but failed: {s}", .{@errorName(err)});
                    };
                },
                .unsubscribe => {
                    self.removeSubscriber(envelope) catch |err| {
                        std.log.err("Tried to remove topic subscription but failed: {s}", .{@errorName(err)});
                    };
                },
            }
        }
        return .rearm;
    }

    pub fn cleanupFrameworkResources(self: *Self) void {
        self.is_shutting_down = true;
        self.inbox.deinit();
        self.arena_state.deinit();
        if (self.completion.op == .noop) {
            self.allocator.destroy(self);
            return;
        }
        cancel_completion = .{
            .op = .{
                .cancel = .{
                    .c = &self.completion,
                },
            },
            .userdata = @ptrCast(self),
            .callback = (struct {
                fn callback(
                    self_: ?*anyopaque,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    r: xev.Result,
                ) xev.CallbackAction {
                    _ = r.cancel catch unreachable;
                    const inner_self: *Self = unsafeAnyOpaqueCast(Self, self_);
                    inner_self.allocator.destroy(inner_self);
                    return .disarm;
                }
            }).callback,
        };
        self.wakeup.deinit();

        self.ctx.engine.loop.add(&cancel_completion);
    }

    fn addSubscriber(self: *Self, envelope: Envelope) !void {
        defer envelope.deinit(self.allocator);
        if (envelope.sender_id == null) {
            return error.SenderIdIsRequired;
        }
        var subscribers = self.ctx.topic_subscriptions.getPtr(envelope.message);
        if (subscribers == null) {
            const owned_topic = try self.allocator.dupe(u8, envelope.message);
            try self.ctx.topic_subscriptions.put(owned_topic, std.StringHashMap(void).init(self.allocator));
            subscribers = self.ctx.topic_subscriptions.getPtr(owned_topic);
        }
        if (subscribers.?.get(envelope.sender_id.?) != null) {
            return;
        }
        const owned_sender_id = try self.allocator.dupe(u8, envelope.sender_id.?);
        try subscribers.?.put(owned_sender_id, {});
    }

    fn removeSubscriber(self: *Self, envelope: Envelope) !void {
        defer envelope.deinit(self.allocator);

        var subscribers = self.ctx.topic_subscriptions.get(envelope.message);
        if (subscribers == null) {
            return error.TopicDoesNotExist;
        }
        if (subscribers.?.fetchRemove(envelope.sender_id.?)) |owned_sender_id| {
            self.allocator.free(owned_sender_id.key);
        }
        if (subscribers.?.count() == 0) {
            if (self.ctx.topic_subscriptions.fetchRemove(envelope.message)) |owned_topic| {
                self.allocator.free(owned_topic.key);
            }
            subscribers.?.deinit();
        }
    }
};

fn makeTypeErasedDeinitFn(comptime ActorType: type) fn (*anyopaque) anyerror!void {
    return struct {
        fn wrapper(ptr: *anyopaque) anyerror!void {
            const self = @as(*ActorType, @ptrCast(@alignCast(ptr)));
            if (comptime hasDeinitMethod(ActorType)) {
                const DeinitFnType = @TypeOf(ActorType.deinit);
                const deinit_fn_info = @typeInfo(DeinitFnType).@"fn";
                const ActualReturnType = deinit_fn_info.return_type.?;

                if (@typeInfo(ActualReturnType) == .error_union) {
                    try ActorType.deinit(self);
                } else {
                    ActorType.deinit(self);
                }
            } else {
                return error.ActorDoesNotHaveDeinitMethod;
            }
        }
    }.wrapper;
}
fn hasDeinitMethod(comptime T: type) bool {
    const typeInfo = @typeInfo(T);
    if (typeInfo != .@"struct") return false;

    inline for (typeInfo.@"struct".decls) |decl| {
        if (!std.mem.eql(u8, decl.name, "deinit")) continue;

        const field = @field(T, decl.name);
        const FieldType = @TypeOf(field);
        const fieldInfo = @typeInfo(FieldType);

        if (fieldInfo != .@"fn") continue;

        const FnInfo = fieldInfo.@"fn";
        if (FnInfo.params.len != 1) continue;

        const ParamType = FnInfo.params[0].type.?;
        if (ParamType != *T) continue;

        return true;
    }

    return false;
}

fn makeTypeErasedReceiveFn(comptime ActorType: type) fn (*anyopaque, Envelope) anyerror!void {
    return struct {
        fn wrapper(ptr: *anyopaque, envelope: Envelope) anyerror!void {
            const self = @as(*ActorType, @ptrCast(@alignCast(ptr)));
            try self.receive(envelope);
        }
    }.wrapper;
}
