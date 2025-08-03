const std = @import("std");
const reg = @import("registry.zig");
const act = @import("actor.zig");
const eng = @import("engine.zig");
const xev = @import("xev");
const type_utils = @import("type_utils.zig");
const engine_internal = @import("engine_internal.zig");
const strm = @import("stream.zig");
const envlp = @import("envelope.zig");

const Allocator = std.mem.Allocator;
const Registry = reg.Registry;
const ActorInterface = act.ActorInterface;
const Engine = eng.Engine;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const StreamHandle = strm.StreamHandle;
const MethodCall = envlp.MethodCall;

pub const Context = struct {
    allocator: Allocator,
    actor_id: []const u8,
    engine: *Engine,
    actor: *ActorInterface,
    timer_completions: std.ArrayList(*xev.Completion),

    const Self = @This();
    pub fn init(allocator: Allocator, engine: *Engine, actor: *ActorInterface, actor_id: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .actor = actor,
            .actor_id = actor_id,
            .timer_completions = std.ArrayList(*xev.Completion).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.deinitTimers();
    }

    pub fn poisonPill(self: *Self) !void {
        try self.engine.poisonPill(self.actor_id);
    }

    pub fn enqueueMethodCall(self: *const Self, target_id: []const u8, method_call: MethodCall) !void {
        try engine_internal.enqueueMethodCall(
            self.engine,
            self.actor_id,
            target_id,
            method_call,
        );
    }

    pub fn publishToStream(self: *const Self, stream_id: []const u8, message: anytype) !void {
        try self.engine.publishToStream(stream_id, message);
    }

    pub fn getStream(self: *const Self, comptime PayloadType: type, id: []const u8) !*StreamHandle(PayloadType) {
        return try self.engine.getStream(PayloadType, id);
    }

    pub fn getLoop(self: *const Self) *xev.Loop {
        return &self.engine.loop;
    }

    pub fn runRecurring(
        self: *Self,
        comptime ActorType: type,
        comptime callback_fn: anytype,
        userdata: ?*anyopaque,
        comptime delay_ms: u64,
    ) !void {
        const completion = try self.allocator.create(xev.Completion);
        try self.timer_completions.append(completion);

        const callback = struct {
            fn inner(
                ud: ?*anyopaque,
                loop: *xev.Loop,
                c: *xev.Completion,
                _: xev.Result,
            ) xev.CallbackAction {
                const actor = unsafeAnyOpaqueCast(ActorType, ud);
                callback_fn(actor) catch |err| {
                    std.log.err("Failed to run callback: {s}", .{@errorName(err)});
                    return .disarm;
                };
                loop.timer(c, delay_ms, ud, inner);
                return .disarm;
            }
        }.inner;

        self.engine.loop.timer(completion, delay_ms, userdata, callback);
    }

    pub fn getActor(self: *const Self, comptime ActorType: type, id: []const u8) !*ActorType {
        return try self.engine.getActor(ActorType, id);
    }

    fn deinitTimers(self: *Self) void {
        for (self.timer_completions.items) |completion| {
            const close_timer_completion = self.allocator.create(xev.Completion) catch |err| {
                std.log.err("Failed to create close timer completion: {s}", .{@errorName(err)});
                return;
            };
            close_timer_completion.* = .{
                .op = .{
                    .cancel = .{
                        .c = completion,
                    },
                },
                .callback = (struct {
                    fn callback(
                        self_: ?*anyopaque,
                        _: *xev.Loop,
                        c: *xev.Completion,
                        r: xev.Result,
                    ) xev.CallbackAction {
                        _ = r.cancel catch unreachable;
                        const inner_self = unsafeAnyOpaqueCast(Self, self_);
                        defer inner_self.allocator.destroy(c);
                        return .disarm;
                    }
                }).callback,
                .userdata = self,
            };
            self.engine.loop.add(close_timer_completion);
        }
        self.timer_completions.deinit();
    }
};
