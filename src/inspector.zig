const std = @import("std");
const envlp = @import("envelope.zig");
const actr = @import("actor.zig");

const ActorInterface = actr.ActorInterface;
const Envelope = envlp.Envelope;

pub const Inspector = struct {
    allocator: std.mem.Allocator,
    mmap_ptr: ?[]align(std.heap.page_size_min) u8 = null,
    inspector_process: ?std.process.Child = null,

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
        };

        return self;
    }

    pub fn envelopeReceived(self: *Inspector, actor: *ActorInterface, _: Envelope) !void {
        return self.tick(actor.ctx.actor_id);
    }

    pub fn tick(
        self: *Inspector,
        message: []const u8,
    ) !void {
        if (self.mmap_ptr) |ptr| {
            @memset(ptr, 0);
            @memcpy(ptr[0..message.len], message);
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
