const reg = @import("registry.zig");
const act = @import("actor.zig");
const actor_ctx = @import("context.zig");
const std = @import("std");
const xev = @import("xev");
const envlp = @import("envelope.zig");
const type_utils = @import("type_utils.zig");
const build_options = @import("build_options");

const os = std.os;
const fs = std.fs;
const mem = std.mem;
const c = std.c;

// This import will always workg© for ZLS
const zignite = if (build_options.enable_inspector) @import("zignite") else {};

const Allocator = std.mem.Allocator;
const Registry = reg.Registry;
const ActorInterface = act.ActorInterface;
const Context = actor_ctx.Context;
const MessageType = envlp.MessageType;
const Envelope = envlp.Envelope;
const unsafeAnyOpaqueCast = type_utils.unsafeAnyOpaqueCast;

pub const ActorOptions = struct {
    id: []const u8,
    capacity: usize = 1024,
};

pub const TestStruct = struct {
    a: u8,
};

pub const Engine = struct {
    registry: Registry,
    allocator: Allocator,
    loop: xev.Loop,
    mmap_ptr: ?[]align(std.heap.page_size_min) u8 = null,
    const Self = @This();
    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .loop = try xev.Loop.init(.{}),
        };
    }

    pub fn run(self: *Self) !void {
        if (build_options.enable_inspector) {
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
            self.mmap_ptr = mmap_ptr;

            const message = "Hello from engine!";
            @memcpy(mmap_ptr[0..message.len], message);
            mmap_ptr[message.len] = 0;

            std.log.info("Engine wrote to mmap: '{s}'", .{message});


            // This is temporarily hardcoded
            const inspector_path = "/Users/thomvanoorschot/Development/backstage/inspector/zig-out/bin/inspector";
            var inspector_process = std.process.Child.init(&[_][]const u8{
                "/usr/bin/open",
                "-a",
                inspector_path,
                "--args",
                temp_file_path,
            }, self.allocator);

            inspector_process.stdin_behavior = .Close;
            inspector_process.stdout_behavior = .Ignore;
            inspector_process.stderr_behavior = .Ignore;

            try inspector_process.spawn();

            std.time.sleep(500_000_000);

        }
        try self.loop.run(.until_done);
    }

    pub fn deinit(self: *Self) void {
        if (self.mmap_ptr) |ptr| {
            std.posix.munmap(ptr);
        }
        self.loop.deinit();
        var it = self.registry.actorsIDMap.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinitFnPtr(entry.value_ptr.*.impl) catch |err| {
                std.log.err("Failed to deinit actor: {s}", .{@errorName(err)});
            };
        }
        self.registry.deinit();
    }

    pub fn spawnActor(self: *Self, comptime ActorType: type, options: ActorOptions) !*ActorType {
        const actor = self.registry.getByID(options.id);
        if (actor) |a| {
            return unsafeAnyOpaqueCast(ActorType, a.impl);
        }
        const actor_interface = try ActorInterface.create(
            self.allocator,
            self,
            ActorType,
            options,
        );
        errdefer actor_interface.deinitFnPtr(actor_interface.impl) catch |err| {
            std.log.err("Failed to deinit actor: {s}", .{@errorName(err)});
        };

        try self.registry.add(options.id, actor_interface);
        return unsafeAnyOpaqueCast(ActorType, actor_interface.impl);
    }
    pub fn removeAndCleanupActor(self: *Self, id: []const u8) !void {
        const actor = self.registry.fetchRemove(id);
        if (actor) |a| {
            a.cleanupFrameworkResources();
        }
    }

    pub fn send(
        self: *Self,
        sender_id: ?[]const u8,
        target_id: []const u8,
        message: anytype,
    ) !void {
        return self.enqueueMessage(
            sender_id,
            target_id,
            .send,
            message,
        );
    }
    pub fn publish(
        self: *Self,
        sender_id: ?[]const u8,
        target_id: []const u8,
        message: anytype,
    ) !void {
        return self.enqueueMessage(
            sender_id,
            target_id,
            .publish,
            message,
        );
    }

    pub fn subscribeToActorTopic(
        self: *Self,
        sender_id: []const u8,
        target_id: []const u8,
        topic: []const u8,
    ) !void {
        return self.enqueueMessage(
            sender_id,
            target_id,
            .subscribe,
            topic,
        );
    }

    pub fn unsubscribeFromActorTopic(
        self: *Self,
        sender_id: []const u8,
        target_id: []const u8,
        topic: []const u8,
    ) !void {
        return self.enqueueMessage(
            sender_id,
            target_id,
            .unsubscribe,
            topic,
        );
    }

    fn enqueueMessage(
        self: *Self,
        sender_id: ?[]const u8,
        target_id: []const u8,
        message_type: MessageType,
        message: anytype,
    ) !void {
        const actor = self.registry.getByID(target_id);
        if (actor) |a| {
            const T = @TypeOf(message);
            switch (@typeInfo(T)) {
                .pointer => |ptr| if (ptr.child != u8) @compileError("Only []const u8 supported"),
                .@"struct" => if (!comptime type_utils.hasMethod(T, "encode")) @compileError("Struct must have encode() method"),
                else => @compileError("Message must be []const u8 or protobuf struct"),
            }

            if (@typeInfo(T) == .@"struct") {
                const encoded = try message.encode(self.allocator);
                defer self.allocator.free(encoded);
                const envelope = Envelope.init(
                    sender_id,
                    message_type,
                    encoded,
                );
                defer envelope.deinit(self.allocator);
                try a.inbox.enqueue(try envelope.toBytes(self.allocator));
            } else {
                const envelope = Envelope.init(
                    sender_id,
                    message_type,
                    message,
                );
                defer envelope.deinit(self.allocator);
                try a.inbox.enqueue(try envelope.toBytes(self.allocator));
            }
        } else {
            std.log.warn("Actor not found: {s}", .{target_id});
        }
    }
};
