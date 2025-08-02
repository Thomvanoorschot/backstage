const std = @import("std");
const reg = @import("registry.zig");
const act = @import("actor.zig");
const eng = @import("engine.zig");
const xev = @import("xev");
const type_utils = @import("type_utils.zig");
const engine_internal = @import("engine_internal.zig");
const strm = @import("stream.zig");

const Allocator = std.mem.Allocator;
const Registry = reg.Registry;
const ActorInterface = act.ActorInterface;
const Engine = eng.Engine;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const StreamHandle = strm.StreamHandle;

pub const Context = struct {
    allocator: Allocator,
    actor_id: []const u8,
    engine: *Engine,
    actor: *ActorInterface,
    parent_actor: ?*ActorInterface,
    child_actors: std.StringHashMap(*ActorInterface),
    timer_completions: std.ArrayList(*xev.Completion),

    // // This is who is subscribed to this actor stored as topic:sender_id
    // topic_subscriptions: std.StringHashMap(std.StringHashMap(void)),

    // // This is who this actor is subscribed to stored as target_id:topic
    // subscribed_to_actors: std.StringHashMap(std.StringHashMap(void)),

    const Self = @This();
    pub fn init(allocator: Allocator, engine: *Engine, actor: *ActorInterface, actor_id: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .engine = engine,
            .child_actors = std.StringHashMap(*ActorInterface).init(allocator),
            .parent_actor = null,
            .actor = actor,
            .actor_id = actor_id,
            // .topic_subscriptions = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            // .subscribed_to_actors = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .timer_completions = std.ArrayList(*xev.Completion).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Cancel and cleanup timer completions
        self.deinitTimers();

        // var topic_it = self.topic_subscriptions.iterator();
        // while (topic_it.next()) |entry| {
        //     entry.value_ptr.deinit();
        // }
        // self.topic_subscriptions.deinit();

        // var sub_it = self.subscribed_to_actors.iterator();
        // while (sub_it.next()) |entry| {
        //     var sub_topic_it = entry.value_ptr.keyIterator();
        //     while (sub_topic_it.next()) |topic| {
        //         self.engine.unsubscribeFromActorTopic(self.actor_id, entry.key_ptr.*, topic.*) catch |err| {
        //             std.log.warn("Failed to unsubscribe from {s} topic {s}: {}", .{ entry.key_ptr.*, topic.*, err });
        //         };
        //     }
        //     entry.value_ptr.deinit();
        // }
        // self.subscribed_to_actors.deinit();

        // // Cleanup child actors
        // var child_it = self.child_actors.valueIterator();
        // while (child_it.next()) |actor| {
        //     engine_internal.deinitActorByReference(self.engine, actor.*);
        // }
        // self.child_actors.deinit();

        // // // Detach from parent
        // if (self.parent_actor) |parent| {
        //     const could_detach = parent.ctx.detachChildActor(self.actor);
        //     if (!could_detach) {
        //         std.log.warn("Failed to detach child actor {s} from parent {s}", .{ self.actor_id, parent.ctx.actor_id });
        //     }
        // }
    }

    pub fn poisonPill(self: *Self) !void {
        try self.engine.poisonPill(self.actor_id);
    }

    pub fn enqueueMethodCall(self: *const Self, target_id: []const u8, message: anytype) !void {
        try engine_internal.enqueueMessage(
            self.engine,
            self.actor_id,
            target_id,
            .method_call,
            message,
        );
    }

    pub fn publishToStream(self: *const Self, stream_id: []const u8, message: anytype) !void {
        try self.engine.publishToStream(stream_id, message);
    }

    pub fn getStream(self: *const Self, comptime PayloadType: type, id: []const u8) !*StreamHandle(PayloadType) {
        return try self.engine.getStream(PayloadType, id);
    }

    // pub fn publish(self: *const Self, message: anytype) !void {
    //     try self.publishToTopic("default", message);
    // }

    // pub fn publishToTopic(self: *const Self, topic: []const u8, message: anytype) !void {
    //     if (self.topic_subscriptions.get(topic)) |subscribers| {
    //         var it = subscribers.keyIterator();
    //         while (it.next()) |id| {
    //             try engine_internal.enqueueMessage(
    //                 self.engine,
    //                 self.actor_id,
    //                 id.*,
    //                 .publish,
    //                 message,
    //             );
    //         }
    //     }
    // }
    // pub fn subscribeToActor(self: *Self, target_id: []const u8) !void {
    //     try self.subscribeToActorTopic(target_id, "default");
    // }

    // pub fn subscribeToActorTopic(self: *Self, target_id: []const u8, topic: []const u8) !void {
    //     var topics = self.subscribed_to_actors.getPtr(target_id);
    //     if (topics == null) {
    //         const owned_target_id = try self.allocator.dupe(u8, target_id);
    //         try self.subscribed_to_actors.put(owned_target_id, std.StringHashMap(void).init(self.allocator));
    //         topics = self.subscribed_to_actors.getPtr(owned_target_id);
    //     }
    //     if (topics.?.get(topic) != null) {
    //         return;
    //     }
    //     const owned_topic = try self.allocator.dupe(u8, topic);
    //     try topics.?.put(owned_topic, {});

    //     try self.engine.subscribeToActorTopic(self.actor_id, target_id, topic);
    // }

    // pub fn unsubscribeFromActor(self: *Self, target_id: []const u8) !void {
    //     try self.unsubscribeFromActorTopic(target_id, "default");
    // }

    // pub fn unsubscribeFromActorTopic(self: *Self, target_id: []const u8, topic: []const u8) !void {
    //     try self.engine.unsubscribeFromActorTopic(self.actor_id, target_id, topic);
    //     var topics = self.subscribed_to_actors.get(target_id);
    //     if (topics == null) {
    //         return error.TargetIdDoesNotExist;
    //     }

    //     if (topics.?.fetchRemove(topic)) |owned_topic| {
    //         self.allocator.free(owned_topic.key);
    //     }

    //     if (topics.?.count() == 0) {
    //         if (self.subscribed_to_actors.fetchRemove(target_id)) |owned_target_id| {
    //             self.allocator.free(owned_target_id.key);
    //         }
    //         topics.?.deinit();
    //     }
    // }

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

    // pub fn spawnChildActor(self: *Self, comptime ActorType: type, options: ActorOptions) !*ActorType {
    //     const actor_impl = try self.engine.spawnActor(ActorType, options);
    //     actor_impl.ctx.parent_actor = self.actor;
    //     try self.child_actors.put(options.id, actor_impl.ctx.actor);
    //     return actor_impl;
    // }
    // pub fn detachChildActor(self: *Self, actor: *ActorInterface) bool {
    //     return self.child_actors.remove(actor.ctx.actor_id);
    // }
    // pub fn detachChildActorByID(self: *Self, id: []const u8) bool {
    //     return self.child_actors.remove(id);
    // }

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
