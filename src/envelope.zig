const std = @import("std");

pub const MessageType = enum(u8) {
    send = 0,
    publish = 1,
    subscribe = 2,
    unsubscribe = 3,
};

pub const Envelope = struct {
    sender_id: ?[]const u8,
    message_type: MessageType,
    message: []const u8,

    pub fn init(
        sender_id: ?[]const u8,
        message_type: MessageType,
        message: []const u8,
    ) Envelope {
        return Envelope{
            .sender_id = sender_id,
            .message_type = message_type,
            .message = message,
        };
    }

    pub fn deinit(self: *const Envelope, allocator: std.mem.Allocator) void {
        if (self.sender_id) |id| {
            allocator.free(id);
        }
        allocator.free(self.message);
    }

    pub fn toBytes(self: *const Envelope, allocator: std.mem.Allocator) ![]u8 {
        const HeaderType = u32;
        const len_field_size = @sizeOf(HeaderType);
        const id_len_size = @sizeOf(u16);

        const sender_id_len: usize = if (self.sender_id) |idSlice| idSlice.len else 0;
        const envelope_type_len: usize = @sizeOf(MessageType);
        const payload_len: usize = self.message.len;

        const remaining_len = id_len_size + sender_id_len + envelope_type_len + payload_len;
        const total_size = len_field_size + remaining_len;

        var buf: []u8 = try allocator.alloc(u8, total_size);

        var idx: usize = 0;

        std.mem.writeInt(HeaderType, @ptrCast(buf[idx .. idx + len_field_size]), @intCast(remaining_len), std.builtin.Endian.big);
        idx += len_field_size;

        std.mem.writeInt(u16, @ptrCast(buf[idx .. idx + id_len_size]), @intCast(sender_id_len), std.builtin.Endian.big);
        idx += id_len_size;

        if (self.sender_id) |idSlice| {
            @memcpy(buf[idx .. idx + sender_id_len], idSlice);
            idx += sender_id_len;
        }

        std.mem.writeInt(u8, @ptrCast(buf[idx .. idx + envelope_type_len]), @intFromEnum(self.message_type), std.builtin.Endian.big);
        idx += envelope_type_len;

        @memcpy(buf[idx .. idx + payload_len], self.message);
        idx += payload_len;

        if (idx != total_size) {
            return error.UnexpectedFrameSize;
        }

        return buf;
    }

    pub fn fromBytes(
        allocator: std.mem.Allocator,
        frame_buf: []const u8,
    ) !Envelope {
        const HeaderType = u32;
        const len_field_size = @sizeOf(HeaderType);
        const id_len_size = @sizeOf(u16);

        if (frame_buf.len < len_field_size + id_len_size) {
            return error.TruncatedFrame;
        }

        const length_minus_4 = std.mem.readInt(HeaderType, @ptrCast(frame_buf[0..len_field_size]), std.builtin.Endian.big);
        if (length_minus_4 + len_field_size != frame_buf.len) {
            return error.InvalidLength;
        }

        const raw_id_len = std.mem.readInt(u16, @ptrCast(frame_buf[len_field_size .. len_field_size + id_len_size]), std.builtin.Endian.big);
        const sender_id_len = raw_id_len;

        if (frame_buf.len < len_field_size + id_len_size + sender_id_len) {
            return error.TruncatedFrame;
        }

        var sender_id: ?[]const u8 = null;
        if (sender_id_len > 0) {
            const sender_id_slice = frame_buf[(len_field_size + id_len_size)..(len_field_size + id_len_size + sender_id_len)];
            sender_id = try allocator.dupe(u8, sender_id_slice);
        }

        const envelope_type_raw = std.mem.readInt(u8, @ptrCast(frame_buf[len_field_size + id_len_size + sender_id_len .. len_field_size + id_len_size + sender_id_len + @sizeOf(MessageType)]), std.builtin.Endian.big);
        const message_type: MessageType = @enumFromInt(envelope_type_raw);
        const payload_start = len_field_size + id_len_size + sender_id_len + @sizeOf(MessageType);
        const payload_out = try allocator.dupe(u8, frame_buf[payload_start..frame_buf.len]);

        return Envelope{
            .sender_id = sender_id,
            .message_type = message_type,
            .message = payload_out,
        };
    }
};
