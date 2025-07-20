// TODO
// While this solution works, this is far from ideal.
// The buffer solution is severly limited and the main process spends too much time 
// storing the state to the buffer. Needs a complete overhaul.
const std = @import("std");
const envlp = @import("../envelope.zig");
const actr = @import("../actor.zig");
const inspst = @import("inspector_state.pb.zig");
const pb = @import("protobuf");
const buffers = @import("buffers.zig");

const ActorInterface = actr.ActorInterface;
const Envelope = envlp.Envelope;
const InspectorState = inspst.InspectorState;
const ActorSnapshot = inspst.ActorSnapshot;
const MessageMetrics = inspst.MessageMetrics;
const ManagedString = pb.ManagedString;
const InboxMetrics = inspst.InboxMetrics;
const InboxThroughputMetrics = inspst.InboxThroughputMetrics;
const SharedBufferWriter = buffers.SharedBufferWriter;
const ActorMessage = inspst.ActorMessage;

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    buffer_writer: SharedBufferWriter,
    inspector_process: ?std.process.Child = null,
    state: InspectorState,

    pub fn init(allocator: std.mem.Allocator) !*Inspector {
        const self = try allocator.create(Inspector);
        const temp_file_path = "/tmp/backstage_mmap_data";

        const buffer_writer = try SharedBufferWriter.init(allocator, temp_file_path);

        var inspector_process = std.process.Child.init(&[_][]const u8{
            "zig-out/bin/inspector",
            temp_file_path,
        }, allocator);

        try inspector_process.spawn();

        self.* = .{
            .allocator = allocator,
            .buffer_writer = buffer_writer,
            .inspector_process = inspector_process,
            .state = InspectorState.init(allocator),
        };

        self.state.inbox_throughput_metrics = .{};

        return self;
    }

    pub fn actorSpawned(self: *Inspector, actor: *ActorInterface) !void {
        try self.state.actors.append(ActorSnapshot{
            .id = try ManagedString.copy(actor.ctx.actor_id, self.allocator),
            .actor_type_name = try ManagedString.copy(actor.actor_type_name, self.allocator),
        });
        try self.tick();
    }

    pub fn actorTerminated(self: *Inspector, actor: *ActorInterface) !void {
        for (self.state.actors.items, 0..) |*actor_snapshot, i| {
            if (std.mem.eql(u8, actor_snapshot.id.Owned.str, actor.ctx.actor_id)) {
                const removed_actor = self.state.actors.swapRemove(i);
                removed_actor.deinit();
                break;
            }
        }
        try self.tick();
    }

    pub fn envelopeReceived(self: *Inspector, actor: *ActorInterface, _: Envelope) !void {
        try updateInboxThroughputMetrics(&self.state.inbox_throughput_metrics.?, @floatFromInt(std.time.milliTimestamp()));

        for (self.state.actors.items) |*actor_snapshot| {
            if (std.mem.eql(u8, actor_snapshot.id.Owned.str, actor.ctx.actor_id)) {
                // actor_snapshot.last_message = ActorMessage{
                //     .sender_id = ManagedString.static("test"),
                //     .message_type = ManagedString.static("test"),
                //     .receiver_id = ManagedString.static("test"),
                //     .received_at = std.time.milliTimestamp(),
                //     // .sender_id = if (envelope.sender_id) |id| try ManagedString.copy(id, self.allocator) else null,
                //     // .message_type = switch (envelope.message_type) {
                //     //     .send => try ManagedString.copy("send", self.allocator),
                //     //     .publish => try ManagedString.copy("publish", self.allocator),
                //     //     .subscribe => try ManagedString.copy("subscribe", self.allocator),
                //     //     .unsubscribe => try ManagedString.copy("unsubscribe", self.allocator),
                //     // },
                //     // .receiver_id = try ManagedString.copy(actor.ctx.actor_id, self.allocator),
                //     // .received_at = std.time.milliTimestamp(),
                // };
                const metrics = &(actor_snapshot.inbox_metrics orelse blk: {
                    actor_snapshot.inbox_metrics = .{};
                    break :blk actor_snapshot.inbox_metrics.?;
                });
                const throughput = &(metrics.throughput_metrics orelse blk: {
                    metrics.throughput_metrics = .{};
                    break :blk metrics.throughput_metrics.?;
                });

                metrics.envelope_count = @intCast(actor.inbox.envelope_count);
                metrics.capacity = @intCast(actor.inbox.capacity);
                metrics.last_message_at = std.time.milliTimestamp();
                try updateInboxThroughputMetrics(throughput, @floatFromInt(std.time.milliTimestamp()));
                break;
            }
        }

        return self.tick();
    }

    pub fn tick(self: *Inspector) !void {
        const message = try self.state.encode(self.allocator);
        defer self.allocator.free(message);

        try self.buffer_writer.writeData(message);
    }

    pub fn deinit(self: *Inspector) void {
        if (self.inspector_process) |*process| {
            _ = process.kill() catch |err| {
                std.log.err("Failed to kill inspector process: {}", .{err});
                return;
            };
            _ = process.wait() catch |err| {
                std.log.err("Failed to wait for inspector process: {}", .{err});
                return;
            };
        }

        self.buffer_writer.deinit();
    }
};

fn updateInboxThroughputMetrics(
    inbox_metrics: *InboxThroughputMetrics,
    now_millis: f64,
) !void {
    inbox_metrics.time = now_millis;
    inbox_metrics.delta_time = @floatCast(inbox_metrics.time - inbox_metrics.previous_time);
    inbox_metrics.previous_time = inbox_metrics.time;

    inbox_metrics.envelope_counter += 1;
    if ((inbox_metrics.time - inbox_metrics.refresh_time) >= 1000.0) {
        const t_millis = inbox_metrics.time - inbox_metrics.refresh_time;
        const eps = @as(f64, @floatFromInt(inbox_metrics.envelope_counter)) / (t_millis / 1000.0);

        if (inbox_metrics.smoothing_factor == 0.0) {
            inbox_metrics.smoothing_factor = 0.1;
        }

        if (inbox_metrics.rolling_average_eps == 0.0) {
            inbox_metrics.rolling_average_eps = eps;
        } else {
            inbox_metrics.rolling_average_eps = inbox_metrics.smoothing_factor * eps +
                (1.0 - inbox_metrics.smoothing_factor) * inbox_metrics.rolling_average_eps;
        }

        inbox_metrics.refresh_time = inbox_metrics.time;
        inbox_metrics.envelope_counter = 0;
    }
}
