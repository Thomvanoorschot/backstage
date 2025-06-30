const std = @import("std");

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

pub const SharedBufferWriter = struct {
    allocator: std.mem.Allocator,
    mmap_ptr: []align(std.heap.page_size_min) u8,
    current_buffer: u32,
    sequence_counter: u64,
    file_path: []const u8,

    const Self = @This();
    const HEADER_SIZE = @sizeOf(SharedMemoryHeader);
    const INITIAL_BUFFER_SIZE = 4096;

    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) !Self {
        const file = try std.fs.createFileAbsolute(file_path, .{ .read = true, .truncate = true });
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

        const writer = Self{
            .allocator = allocator,
            .mmap_ptr = mmap_ptr,
            .current_buffer = 0,
            .sequence_counter = 0,
            .file_path = file_path,
        };

        const header = @as(*SharedMemoryHeader, @ptrCast(@alignCast(mmap_ptr.ptr)));
        header.* = SharedMemoryHeader.init();

        return writer;
    }

    pub fn writeData(self: *Self, data: []const u8) !void {
        const write_buffer_index = 1 - self.current_buffer;
        const required_size = HEADER_SIZE + (INITIAL_BUFFER_SIZE * 2) + data.len;

        if (self.mmap_ptr.len < required_size) {
            try self.resizeBuffer(required_size);
        }

        const header = @as(*SharedMemoryHeader, @ptrCast(@alignCast(self.mmap_ptr.ptr)));

        if (!header.isValid()) {
            header.* = SharedMemoryHeader.init();
        }

        const buffer_offset = HEADER_SIZE + (write_buffer_index * INITIAL_BUFFER_SIZE);
        const buffer_start = self.mmap_ptr[buffer_offset..];

        @memcpy(buffer_start[0..data.len], data);

        self.sequence_counter += 1;

        @atomicStore(u32, &header.buffer_sizes[write_buffer_index], @intCast(data.len), .release);
        @atomicStore(u64, &header.sequences[write_buffer_index], self.sequence_counter, .release);

        _ = @atomicRmw(u64, &header.sync_counter, .Add, 1, .seq_cst);

        @atomicStore(u32, &header.active_buffer, write_buffer_index, .seq_cst);

        self.current_buffer = write_buffer_index;
    }

    fn resizeBuffer(self: *Self, required_size: usize) !void {
        std.posix.munmap(self.mmap_ptr);

        const file = try std.fs.openFileAbsolute(self.file_path, .{ .mode = .read_write });
        defer file.close();

        const new_size = required_size + 4096;
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

    pub fn deinit(self: *Self) void {
        std.posix.munmap(self.mmap_ptr);
    }
};

pub const SharedBufferReader = struct {
    mmap_ptr: []align(std.heap.page_size_min) u8,
    last_sequence: u64,
    last_sync_counter: u64,

    const HEADER_SIZE = @sizeOf(SharedMemoryHeader);
    const INITIAL_BUFFER_SIZE = 4096;

    const Self = @This();
    pub fn init(file_path: []const u8) !Self {
        const file = try std.fs.openFileAbsolute(file_path, .{ .mode = .read_only });
        defer file.close();

        const file_stat = try file.stat();
        const file_size = @max(file_stat.size, 1);

        const mmap_ptr = try std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );

        return Self{
            .mmap_ptr = mmap_ptr,
            .last_sequence = 0,
            .last_sync_counter = 0,
        };
    }

    pub fn readData(self: *Self, allocator: std.mem.Allocator) !?[]u8 {
        const header = @as(*const SharedMemoryHeader, @ptrCast(@alignCast(self.mmap_ptr.ptr)));

        if (!header.isValid()) {
            return null;
        }

        const sync_counter = @atomicLoad(u64, &header.sync_counter, .seq_cst);
        if (sync_counter <= self.last_sync_counter) {
            return null;
        }

        const active_buffer_start = @atomicLoad(u32, &header.active_buffer, .acquire);
        if (active_buffer_start >= 2) {
            return null;
        }

        const sequence = @atomicLoad(u64, &header.sequences[active_buffer_start], .acquire);
        const buffer_size = @atomicLoad(u32, &header.buffer_sizes[active_buffer_start], .acquire);

        if (sequence <= self.last_sequence) {
            return null;
        }

        if (buffer_size == 0 or buffer_size > INITIAL_BUFFER_SIZE) {
            return null;
        }

        const buffer_offset = HEADER_SIZE + (active_buffer_start * INITIAL_BUFFER_SIZE);
        if (buffer_offset + buffer_size > self.mmap_ptr.len) {
            return null;
        }

        const data_copy = try allocator.alloc(u8, buffer_size);
        const buffer_start = self.mmap_ptr[buffer_offset..];
        @memcpy(data_copy, buffer_start[0..buffer_size]);

        const active_buffer_end = @atomicLoad(u32, &header.active_buffer, .acquire);
        const sequence_check = @atomicLoad(u64, &header.sequences[active_buffer_start], .acquire);
        const sync_counter_check = @atomicLoad(u64, &header.sync_counter, .seq_cst);

        if (active_buffer_end != active_buffer_start or
            sequence_check != sequence or
            sync_counter_check != sync_counter)
        {
            allocator.free(data_copy);
            return null;
        }

        self.last_sequence = sequence;
        self.last_sync_counter = sync_counter;
        return data_copy;
    }

    pub fn deinit(self: *Self) void {
        std.posix.munmap(self.mmap_ptr);
    }
};
