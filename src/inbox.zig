const std = @import("std");
const envlp = @import("envelope.zig");

const Envelope = envlp.Envelope;

pub const Inbox = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    capacity: usize,
    head: usize,
    tail: usize,
    len: usize,
    envelope_count: usize,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) !*Inbox {
        var cap = @max(1, initial_capacity);
        if (!std.math.isPowerOfTwo(cap)) {
            cap = std.math.ceilPowerOfTwo(usize, cap) catch unreachable;
        }

        const buf = try allocator.alloc(u8, cap);
        const inbox = try allocator.create(Inbox);
        inbox.* = .{
            .allocator = allocator,
            .buffer = buf,
            .capacity = cap,
            .head = 0,
            .tail = 0,
            .len = 0,
            .envelope_count = 0,
        };
        return inbox;
    }

    pub fn deinit(self: *Inbox) void {
        self.allocator.free(self.buffer);
    }

    pub fn isEmpty(self: *const Inbox) bool {
        return self.len == 0;
    }

    fn isFull(self: *const Inbox, needed: usize) bool {
        return (self.capacity - self.len) < needed;
    }

    pub fn enqueue(self: *Inbox, envelope_bytes: []const u8) !void {
        const header_size = @sizeOf(usize);
        const msg_len = envelope_bytes.len;
        const total_needed = header_size + msg_len;

        if (self.isFull(total_needed)) {
            try self.grow(self.capacity * 2);
        }

        var len_header: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &len_header, msg_len, .little);

        for (len_header) |byte| {
            self.buffer[self.tail] = byte;
            self.tail = (self.tail + 1) & (self.capacity - 1);
        }

        for (envelope_bytes) |byte| {
            self.buffer[self.tail] = byte;
            self.tail = (self.tail + 1) & (self.capacity - 1);
        }
        self.len += total_needed;
        self.envelope_count += 1;
    }

    pub fn dequeue(self: *Inbox) !?Envelope {
        if (self.isEmpty()) {
            return null;
        }

        const header_size = @sizeOf(usize);

        var len_bytes: [@sizeOf(usize)]u8 = undefined;
        for (&len_bytes) |*b| {
            b.* = self.buffer[self.head];
            self.head = (self.head + 1) & (self.capacity - 1);
        }
        const msg_len = std.mem.readInt(usize, &len_bytes, .little);

        const msg_buf = try self.allocator.alloc(u8, msg_len);
        defer self.allocator.free(msg_buf);

        var idx: usize = 0;
        while (idx < msg_len) : (idx += 1) {
            msg_buf[idx] = self.buffer[self.head];
            self.head = (self.head + 1) & (self.capacity - 1);
        }

        self.len -= (header_size + msg_len);
        self.envelope_count -= 1;
        return try Envelope.fromBytes(self.allocator, msg_buf);
    }

    fn grow(self: *Inbox, new_cap: usize) !void {
        const new_buf = try self.allocator.alloc(u8, new_cap);

        var read_pos = self.head;
        var write_pos: usize = 0;
        var remaining = self.len;
        while (remaining > 0) : (remaining -= 1) {
            new_buf[write_pos] = self.buffer[read_pos];
            read_pos = (read_pos + 1) & (self.capacity - 1);
            write_pos += 1;
        }

        self.allocator.free(self.buffer);

        self.buffer = new_buf;
        self.capacity = new_cap;
        self.head = 0;
        self.tail = write_pos;
    }
};
