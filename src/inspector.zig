const std = @import("std");
const envlp = @import("envelope.zig");
const actr = @import("actor.zig");
const inspst = @import("inspector_state.pb.zig");
const pb = @import("protobuf");

const ActorInterface = actr.ActorInterface;
const Envelope = envlp.Envelope;
const InspectorState = inspst.InspectorState;
const ActorSnapshot = inspst.ActorSnapshot;
const MessageMetrics = inspst.MessageMetrics;
const ManagedString = pb.ManagedString;
const InboxMetrics = inspst.InboxMetrics;
const InboxThroughputMetrics = inspst.InboxThroughputMetrics;

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

        inbox_metrics.envelopes_per_second = eps;
        inbox_metrics.refresh_time = inbox_metrics.time;
        inbox_metrics.envelope_counter = 0;
    }
}

const SharedBuffer = struct {
    data: []u8,
    size: u32,
    sequence: u64,

    fn init(allocator: std.mem.Allocator, initial_size: usize) !SharedBuffer {
        return SharedBuffer{
            .data = try allocator.alloc(u8, initial_size),
            .size = 0,
            .sequence = 0,
        };
    }

    fn deinit(self: *SharedBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    fn ensureCapacity(self: *SharedBuffer, allocator: std.mem.Allocator, needed_size: usize) !void {
        if (self.data.len < needed_size) {
            const new_capacity = @max(needed_size, self.data.len * 2);
            const new_data = try allocator.alloc(u8, new_capacity);
            allocator.free(self.data);
            self.data = new_data;
        }
    }
};

const SharedMemoryHeader = struct {
    const MAGIC: u32 = 0xDEADBEEF;
    const VERSION: u32 = 1;

    magic: u32,
    version: u32,
    active_buffer: u32,
    buffer_sizes: [2]u32,
    sequences: [2]u64,
    sync_counter: u64, 

    fn init() SharedMemoryHeader {
        return SharedMemoryHeader{
            .magic = MAGIC,
            .version = VERSION,
            .active_buffer = 0,
            .buffer_sizes = [2]u32{ 0, 0 },
            .sequences = [2]u64{ 0, 0 },
            .sync_counter = 0,
        };
    }

    fn isValid(self: *const SharedMemoryHeader) bool {
        return self.magic == MAGIC and self.version == VERSION;
    }
};

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    mmap_ptr: ?[]align(std.heap.page_size_min) u8 = null,
    inspector_process: ?std.process.Child = null,
    state: InspectorState,
    buffers: [2]SharedBuffer,
    current_buffer: u32,
    sequence_counter: u64,

    const HEADER_SIZE = @sizeOf(SharedMemoryHeader);
    const INITIAL_BUFFER_SIZE = 4096;

    pub fn init(allocator: std.mem.Allocator) !*Inspector {
        const self = try allocator.create(Inspector);
        const temp_file_path = "/tmp/backstage_mmap_data";
        const file = try std.fs.createFileAbsolute(temp_file_path, .{ .read = true, .truncate = true });
        defer file.close();

        const initial_file_size = HEADER_SIZE + (INITIAL_BUFFER_SIZE * 2);
        try file.setEndPos(initial_file_size);

        const mmap_ptr = try std.posix.mmap(
            null,
            initial_file_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        var inspector_process = std.process.Child.init(&[_][]const u8{
            "zig-out/bin/inspector",
            temp_file_path,
        }, allocator);

        try inspector_process.spawn();

        const buffers = [2]SharedBuffer{
            try SharedBuffer.init(allocator, 0), 
            try SharedBuffer.init(allocator, 0),
        };

        self.* = .{
            .allocator = allocator,
            .mmap_ptr = mmap_ptr,
            .inspector_process = inspector_process,
            .state = InspectorState.init(allocator),
            .buffers = buffers,
            .current_buffer = 0,
            .sequence_counter = 0,
        };

        const header = @as(*SharedMemoryHeader, @ptrCast(@alignCast(mmap_ptr.ptr)));
        header.* = SharedMemoryHeader.init();

        self.state.inbox_throughput_metrics = .{};

        return self;
    }

    pub fn actorSpawned(self: *Inspector, actor: *ActorInterface) !void {
        try self.state.actors.append(ActorSnapshot{ .id = try ManagedString.copy(actor.ctx.actor_id, self.allocator) });
        try self.tick();
    }

    pub fn actorTerminated(self: *Inspector, actor: *ActorInterface) !void {
        for (self.state.actors.items, 0..) |*actor_snapshot, i| {
            if (std.mem.eql(u8, actor_snapshot.id.Owned.str, actor.ctx.actor_id)) {
                _ = self.state.actors.swapRemove(i);
                break;
            }
        }
        try self.tick();
    }

    pub fn envelopeReceived(self: *Inspector, actor: *ActorInterface, _: Envelope) !void {
        try updateInboxThroughputMetrics(&self.state.inbox_throughput_metrics.?, @floatFromInt(std.time.milliTimestamp()));

        for (self.state.actors.items) |*actor_snapshot| {
            if (std.mem.eql(u8, actor_snapshot.id.Owned.str, actor.ctx.actor_id)) {
                const metrics = &(actor_snapshot.inbox_metrics orelse blk: {
                    actor_snapshot.inbox_metrics = .{};
                    break :blk actor_snapshot.inbox_metrics.?;
                });
                const throughput = &(metrics.throughput_metrics orelse blk: {
                    metrics.throughput_metrics = .{};
                    break :blk metrics.throughput_metrics.?;
                });

                metrics.len = @intCast(actor.inbox.len);
                metrics.capacity = @intCast(actor.inbox.capacity);
                metrics.last_message_at = std.time.milliTimestamp();
                try updateInboxThroughputMetrics(throughput, @floatFromInt(std.time.milliTimestamp()));
                break;
            }
        }

        return self.tick();
    }

    pub fn tick(self: *Inspector) !void {
        if (self.mmap_ptr) |ptr| {
            const message = try self.state.encode(self.allocator);
            defer self.allocator.free(message);

            const write_buffer_index = 1 - self.current_buffer;
            const required_size = HEADER_SIZE + (INITIAL_BUFFER_SIZE * 2) + message.len;

            if (ptr.len < required_size) {
                std.posix.munmap(ptr);

                const temp_file_path = "/tmp/backstage_mmap_data";
                const file = try std.fs.openFileAbsolute(temp_file_path, .{ .mode = .read_write });
                defer file.close();

                const new_size = required_size + 4096;
                try file.setEndPos(new_size);

                const new_mmap_ptr = try std.posix.mmap(
                    null,
                    new_size,
                    std.posix.PROT.READ | std.posix.PROT.WRITE,
                    .{ .TYPE = .SHARED },
                    file.handle,
                    0,
                );

                self.mmap_ptr = new_mmap_ptr;
            }

            if (self.mmap_ptr) |updated_ptr| {
                const header = @as(*SharedMemoryHeader, @ptrCast(@alignCast(updated_ptr.ptr)));

                if (!header.isValid()) {
                    header.* = SharedMemoryHeader.init();
                }

                const buffer_offset = HEADER_SIZE + (write_buffer_index * INITIAL_BUFFER_SIZE);
                const buffer_start = updated_ptr[buffer_offset..];

                @memcpy(buffer_start[0..message.len], message);

                self.sequence_counter += 1;

                @atomicStore(u32, &header.buffer_sizes[write_buffer_index], @intCast(message.len), .release);
                @atomicStore(u64, &header.sequences[write_buffer_index], self.sequence_counter, .release);

                _ = @atomicRmw(u64, &header.sync_counter, .Add, 1, .seq_cst);

                @atomicStore(u32, &header.active_buffer, write_buffer_index, .seq_cst);

                self.current_buffer = write_buffer_index;
            }
        }
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

        if (self.mmap_ptr) |ptr| {
            std.posix.munmap(ptr);
        }

        self.buffers[0].deinit(self.allocator);
        self.buffers[1].deinit(self.allocator);
    }
};
