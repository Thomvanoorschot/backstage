const reg = @import("registry.zig");
const act = @import("actor.zig");
const actor_ctx = @import("context.zig");
const std = @import("std");
const xev = @import("xev");
const envlp = @import("envelope.zig");
const type_utils = @import("type_utils.zig");
const build_options = @import("build_options");
const ispct = @import("inspector/inspector.zig");
const zignite = if (build_options.enable_inspector) @import("zignite") else {};
const internal = @import("engine_internal.zig");
const strm_registry = @import("stream_registry.zig");
const strm = @import("stream.zig");

const Allocator = std.mem.Allocator;
const Registry = reg.Registry;
const ActorInterface = act.ActorInterface;
const Context = actor_ctx.Context;
const MessageType = envlp.MessageType;
const Envelope = envlp.Envelope;
const MethodCall = envlp.MethodCall;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;
const Inspector = ispct.Inspector;
const StreamRegistry = strm_registry.StreamRegistry;
const StreamSubscribeRequest = strm_registry.StreamSubscribeRequest;
const Stream = strm.Stream;
const StreamHandle = strm.StreamHandle;

pub const Engine = struct {
    registry: Registry,
    stream_registry: StreamRegistry,
    allocator: Allocator,
    loop: xev.Loop,
    inspector: ?*Inspector = null,
    const Self = @This();
    pub fn init(allocator: Allocator) !Self {
        const registry = Registry.init(allocator);
        const inspector = if (build_options.enable_inspector) try Inspector.init(allocator) else null;
        return Self{
            .allocator = allocator,
            .loop = try xev.Loop.init(.{}),
            .registry = registry,
            .stream_registry = StreamRegistry.init(allocator),
            .inspector = inspector,
        };
    }

    pub fn run(self: *Self) !void {
        try self.loop.run(.until_done);
    }

    pub fn deinit(self: *Self) void {
        if (self.inspector != null) {
            self.inspector.?.deinit();
        }
        self.loop.deinit();
        var actor_it = self.registry.actorsIDMap.iterator();
        while (actor_it.next()) |entry| {
            // We are calling the deinit function for the actor implementation here.
            // Normally the deinit function is called on the actor interface itself,
            // but the engine itself is being deinitialized.
            entry.value_ptr.*.deinitFnPtr(entry.value_ptr.*.impl) catch |err| {
                std.log.err("Failed to deinit actor: {s}", .{@errorName(err)});
            };
            internal.deinitActorByReference(self, entry.value_ptr.*);
        }
        self.registry.deinit();
        self.stream_registry.deinit();
    }

    pub fn getActor(self: *Self, comptime ActorType: type, id: []const u8) !*ActorType {
        if (!@hasDecl(ActorType, "is_proxy")) {
            @compileError("getActor can only be used with proxy types. Use the generated proxy types instead of the raw actor types.");
        }
        const actor = self.registry.getByID(id);
        if (actor) |a| {
            return unsafeAnyOpaqueCast(ActorType, a.impl);
        }
        const actor_interface = try ActorInterface.init(
            self.allocator,
            self,
            ActorType,
            id,
            self.inspector,
        );
        errdefer actor_interface.deinitFnPtr(actor_interface.impl) catch |err| {
            std.log.err("Failed to deinit actor: {s}", .{@errorName(err)});
        };

        try self.registry.add(id, actor_interface);
        if (self.inspector != null) {
            self.inspector.?.actorSpawned(actor_interface) catch |err| {
                std.log.warn("Tried to update inspector but failed: {s}", .{@errorName(err)});
            };
        }
        return unsafeAnyOpaqueCast(ActorType, actor_interface.impl);
    }

    pub fn getStream(self: *Engine, comptime PayloadType: type, id: []const u8) !*StreamHandle(PayloadType) {
        const entry = self.stream_registry.getByID(id);
        if (entry) |e| {
            return unsafeAnyOpaqueCast(StreamHandle(PayloadType), e.handle_ptr);
        }
        const stream = try Stream.init(self.allocator, self, id, PayloadType);
        try self.stream_registry.add(id, stream);
        return unsafeAnyOpaqueCast(StreamHandle(PayloadType), stream.handle_ptr);
    }

    pub fn publishToStream(self: *Engine, stream_id: []const u8, encoded_data: []const u8) !void {
        const subscriptions = self.stream_registry.getSubscriptions(stream_id);
        for (subscriptions) |subscription| {
            try internal.enqueueMessage(
                self,
                null,
                subscription.actor_id,
                .method_call,
                MethodCall{
                    .method_id = subscription.method_id,
                    .params = encoded_data,
                },
            );
        }
    }
    pub fn poisonPill(self: *Self, target_id: []const u8) !void {
        return internal.enqueueMessage(
            self,
            null,
            target_id,
            .poison_pill,
            "",
        );
    }
};
