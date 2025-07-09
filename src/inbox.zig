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

    pub fn enqueue(self: *Inbox, envelope: Envelope) !void {
        const envelope_bytes = try envelope.toBytes(self.allocator);
        defer self.allocator.free(envelope_bytes);

        const header_size = @sizeOf(usize);
        const msg_len = envelope_bytes.len;
        const total_needed = header_size + msg_len;

        if (self.isFull(total_needed)) {
            const min_needed = self.len + total_needed;
            const new_cap = try std.math.ceilPowerOfTwo(usize, min_needed);
            try self.grow(new_cap);
        }

        var len_header: [@sizeOf(usize)]u8 = undefined;
        std.mem.writeInt(usize, &len_header, msg_len, .little);

        self.writeToBuffer(&len_header);
        self.writeToBuffer(envelope_bytes);

        self.len += total_needed;
        self.envelope_count += 1;
    }

    pub fn dequeue(self: *Inbox) !?Envelope {
        if (self.isEmpty()) {
            return null;
        }

        const header_size = @sizeOf(usize);

        var len_bytes: [@sizeOf(usize)]u8 = undefined;
        self.readFromBuffer(&len_bytes);
        const msg_len = std.mem.readInt(usize, &len_bytes, .little);

        const envelope = if (self.head + msg_len <= self.capacity) blk: {
            // No wraparound
            const slice = self.buffer[self.head .. self.head + msg_len];
            self.head += msg_len;
            break :blk try Envelope.fromBytes(self.allocator, slice);
        } else blk: {
            const temp_buf = try self.allocator.alloc(u8, msg_len);
            defer self.allocator.free(temp_buf);
            self.readFromBuffer(temp_buf);
            break :blk try Envelope.fromBytes(self.allocator, temp_buf);
        };

        self.len -= (header_size + msg_len);
        self.envelope_count -= 1;

        return envelope;
    }

    pub fn peekEnvelope(self: *Inbox) !?struct { envelope: Envelope, size: usize } {
        if (self.isEmpty()) {
            return null;
        }

        const header_size = @sizeOf(usize);
        const saved_head = self.head;

        var len_bytes: [@sizeOf(usize)]u8 = undefined;
        self.readFromBuffer(&len_bytes);
        const msg_len = std.mem.readInt(usize, &len_bytes, .little);
        const total_size = header_size + msg_len;

        const envelope = if (self.head + msg_len <= self.capacity) blk: {
            // No wraparound
            const slice = self.buffer[self.head .. self.head + msg_len];
            break :blk try Envelope.fromBytes(self.allocator, slice);
        } else blk: {
            const temp_buf = try self.allocator.alloc(u8, msg_len);
            defer self.allocator.free(temp_buf);
            self.readFromBuffer(temp_buf);
            break :blk try Envelope.fromBytes(self.allocator, temp_buf);
        };

        self.head = saved_head;

        return .{ .envelope = envelope, .size = total_size };
    }

    pub fn consumeEnvelope(self: *Inbox, size: usize) void {
        self.head = (self.head + size) & (self.capacity - 1);
        self.len -= size;
        self.envelope_count -= 1;
    }

    pub fn getEnvelopeCount(self: *const Inbox) usize {
        return self.envelope_count;
    }

    pub fn hasEnvelopes(self: *const Inbox) bool {
        return self.envelope_count > 0;
    }

    fn grow(self: *Inbox, new_cap: usize) !void {
        std.log.info("growing inbox from {d} to {d}", .{ self.capacity, new_cap });
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

    fn writeToBuffer(self: *Inbox, data: []const u8) void {
        if (self.tail + data.len <= self.capacity) {
            // No wraparound
            @memcpy(self.buffer[self.tail .. self.tail + data.len], data);
            self.tail += data.len;
            return;
        }
        const first_chunk = self.capacity - self.tail;
        const second_chunk = data.len - first_chunk;

        @memcpy(self.buffer[self.tail..self.capacity], data[0..first_chunk]);
        @memcpy(self.buffer[0..second_chunk], data[first_chunk..]);
        self.tail = second_chunk;
    }

    fn readFromBuffer(self: *Inbox, data: []u8) void {
        if (self.head + data.len <= self.capacity) {
            // No wraparound
            @memcpy(data, self.buffer[self.head .. self.head + data.len]);
            self.head += data.len;
            return;
        }
        const first_chunk = self.capacity - self.head;
        const second_chunk = data.len - first_chunk;

        @memcpy(data[0..first_chunk], self.buffer[self.head..self.capacity]);
        @memcpy(data[first_chunk..], self.buffer[0..second_chunk]);
        self.head = second_chunk;
    }

    fn peekFromBuffer(self: *const Inbox, start_offset: usize, data: []u8) void {
        const read_pos = (self.head + start_offset) & (self.capacity - 1);

        if (read_pos + data.len <= self.capacity) {
            // No wraparound
            @memcpy(data, self.buffer[read_pos .. read_pos + data.len]);
            return;
        }
        const first_chunk = self.capacity - read_pos;
        const second_chunk = data.len - first_chunk;

        @memcpy(data[0..first_chunk], self.buffer[read_pos..self.capacity]);
        @memcpy(data[first_chunk..], self.buffer[0..second_chunk]);
    }

    fn canReadDirectly(self: *const Inbox, start_offset: usize, len: usize) bool {
        const read_pos = (self.head + start_offset) & (self.capacity - 1);
        return read_pos + len <= self.capacity;
    }
};
