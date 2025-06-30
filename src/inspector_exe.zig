const std = @import("std");
const zignite = @import("zignite");
const inspst = @import("inspector_state.pb.zig");

const imgui = zignite.imgui;
const engine = zignite.engine;
const InspectorState = inspst.InspectorState;

const SharedMemoryHeader = struct {
    const MAGIC: u32 = 0xDEADBEEF;
    const VERSION: u32 = 1;

    magic: u32,
    version: u32,
    active_buffer: u32,
    buffer_sizes: [2]u32,
    sequences: [2]u64,
    sync_counter: u64, 

    fn isValid(self: *const SharedMemoryHeader) bool {
        return self.magic == MAGIC and self.version == VERSION;
    }
};

const SafeReader = struct {
    mmap_ptr: []align(std.heap.page_size_min) u8,
    last_sequence: u64,
    last_sync_counter: u64,

    const HEADER_SIZE = @sizeOf(SharedMemoryHeader);
    const INITIAL_BUFFER_SIZE = 4096;

    fn init(mmap_ptr: []align(std.heap.page_size_min) u8) SafeReader {
        return SafeReader{
            .mmap_ptr = mmap_ptr,
            .last_sequence = 0,
            .last_sync_counter = 0,
        };
    }

    fn readData(self: *SafeReader, allocator: std.mem.Allocator) !?[]u8 {
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
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <temp_file_path>\n", .{args[0]});
        return;
    }

    const file_path = args[1];
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
    defer std.posix.munmap(mmap_ptr);

    var e = try engine.Engine.init(.{
        .width = 1024,
        .height = 768,
    });
    defer e.deinit();

    var reader = SafeReader.init(mmap_ptr);
    var last_state: ?InspectorState = null;

    while (e.startRender()) {
        defer e.endRender();

        if (reader.readData(allocator)) |data| {
            if (data != null) {
                defer allocator.free(data.?);

                if (InspectorState.decode(data.?, allocator)) |new_state| {
                    if (last_state) |*old_state| {
                        old_state.deinit();
                    }
                    last_state = new_state;
                } else |err| {
                    std.log.warn("Failed to decode inspector state: {}", .{err});
                }
            }
        } else |err| {
            std.log.debug("Failed to read data: {}", .{err});
        }

        if (imgui.igBegin("Backstage Inspector", null, 0)) {
            if (last_state) |data| {
                if (imgui.igBeginTabBar("InspectorTabs", 0)) {
                    if (imgui.igBeginTabItem("Actor", null, 0)) {
                        imgui.igText("Actor Count: %d", data.actors.items.len);
                        imgui.igText(
                            "Messages Per Second: %.2f",
                            if (data.inbox_throughput_metrics != null)
                                data.inbox_throughput_metrics.?.envelopes_per_second
                            else
                                0.0,
                        );
                        for (data.actors.items) |actor| {
                            if (imgui.igTreeNode_Str(actor.id.Owned.str.ptr)) {
                                if (actor.inbox_metrics) |metrics| {
                                    imgui.igText("Inbox Length: %d", metrics.len);
                                    imgui.igText("Inbox Capacity: %d", metrics.capacity);
                                    if (metrics.throughput_metrics) |throughput| {
                                        imgui.igText("Messages Per Second: %.2f", throughput.envelopes_per_second);
                                    }
                                }
                                imgui.igTreePop();
                            }
                        }
                        imgui.igEndTabItem();
                    }
                    if (imgui.igBeginTabItem("Performance", null, 0)) {
                        imgui.igText("Performance metrics here");
                        imgui.igEndTabItem();
                    }
                    imgui.igEndTabBar();
                }
            } else {
                imgui.igText("No data available");
            }
        }
        imgui.igEnd();
    }

    if (last_state) |*ls| {
        ls.deinit();
    }
}
