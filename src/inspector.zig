const std = @import("std");
const envlp = @import("envelope.zig");
const actr = @import("actor.zig");
const inspst = @import("inspector_state.pb.zig");
const pb = @import("protobuf");

const ActorInterface = actr.ActorInterface;
const Envelope = envlp.Envelope;
const InspectorState = inspst.InspectorState;
const ActorSnapshot = inspst.ActorSnapshot;
const ManagedString = pb.ManagedString;

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    mmap_ptr: ?[]align(std.heap.page_size_min) u8 = null,
    inspector_process: ?std.process.Child = null,
    state: InspectorState,

    pub fn init(allocator: std.mem.Allocator) !*Inspector {
        const self = try allocator.create(Inspector);
        const temp_file_path = "/tmp/backstage_mmap_data";
        const file = try std.fs.createFileAbsolute(temp_file_path, .{ .read = true, .truncate = true });
        defer file.close();

        const file_size = 1024;
        try file.setEndPos(file_size);

        const mmap_ptr = try std.posix.mmap(
            null,
            file_size,
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

        self.* = .{
            .allocator = allocator,
            .mmap_ptr = mmap_ptr,
            .inspector_process = inspector_process,
            .state = InspectorState.init(allocator),
        };

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

    pub fn envelopeReceived(self: *Inspector, _: *ActorInterface, _: Envelope) !void {
        // try self.state.envelopeReceived(actor, envelope);
        return self.tick();
    }

    pub fn tick(
        self: *Inspector,
    ) !void {
        if (self.mmap_ptr) |ptr| {
            const message = try self.state.encode(self.allocator);

            if (message.len > ptr.len) {
                std.posix.munmap(ptr);

                const temp_file_path = "/tmp/backstage_mmap_data";
                const file = try std.fs.openFileAbsolute(temp_file_path, .{ .mode = .read_write });
                defer file.close();

                const new_size = message.len + 256;
                std.log.info("Resizing mmap to {d} bytes", .{new_size});
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
                @memset(updated_ptr, 0);
                @memcpy(updated_ptr[0..message.len], message);
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
    }
};
