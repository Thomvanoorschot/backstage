const std = @import("std");
const zignite = @import("zignite");
const inspst = @import("inspector_state.pb.zig");

const imgui = zignite.imgui;
const engine = zignite.engine;
const InspectorState = inspst.InspectorState;

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

    var last_state: ?InspectorState = null;
    var last_state_hash: u64 = 0;

    while (e.startRender()) {
        defer e.endRender();

        const length_bytes = mmap_ptr[0..4];
        const data_length = std.mem.readInt(u32, length_bytes[0..4], .little);

        if (data_length == 0 or data_length > file_size - 4) {
            std.log.info("Invalid data length: {d}", .{data_length});
            continue;
        }

        const data_copy = try allocator.alloc(u8, data_length);
        defer allocator.free(data_copy);
        @memcpy(data_copy, mmap_ptr[4 .. 4 + data_length]);

        const length_check = std.mem.readInt(u32, mmap_ptr[0..4], .little);
        if (length_check != data_length) {
            std.log.info("Length check mismatch: {d} != {d}", .{ length_check, data_length });
            continue;
        }

        const current_hash = std.hash_map.hashString(data_copy);
        if (current_hash != last_state_hash) {
            if (last_state) |*ls| {
                ls.deinit();
            }

            last_state = InspectorState.decode(data_copy, allocator) catch |err| {
                std.log.warn("Failed to decode inspector state: {}", .{err});
                last_state = null;
                last_state_hash = 0;
                continue;
            };
            last_state_hash = current_hash;
        }

        if (imgui.igBegin("Backstage Inspector", null, 0)) {
            if (last_state) |data| {
                if (imgui.igBeginTabBar("InspectorTabs", 0)) {
                    if (imgui.igBeginTabItem("Actor", null, 0)) {
                        imgui.igText("Actzor Count: %d", data.actors.items.len);
                        imgui.igText(
                            "Messages Per Second: %.2f",
                            if (data.inbox_throughput_metrics != null)
                                data.inbox_throughput_metrics.?.envelopes_per_second
                            else
                                0.0,
                        );
                        for (data.actors.items) |actor| {
                            if (imgui.igTreeNode_Str(actor.id.Owned.str.ptr)) {
                                // imgui.igText("Last Message At: %d", actor.message_metrics.?.last_message_at);
                                imgui.igText("Messages Per Second: %.2f", actor.inbox_metrics.?.throughput_metrics.?.envelopes_per_second);
                                imgui.igTreePop();
                            }
                        }
                        imgui.igEndTabItem();
                    }
                    if (imgui.igBeginTabItem("Performance", null, 0)) {
                        imgui.igText("Performance metrics here", .{});
                        imgui.igEndTabItem();
                    }
                    imgui.igEndTabBar();
                }
            } else {
                imgui.igText("No data available", .{});
            }
        }
        imgui.igEnd();
    }

    if (last_state) |*ls| {
        ls.deinit();
    }
}
