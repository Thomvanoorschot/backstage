const std = @import("std");
const zignite = @import("zignite");
const inspst = @import("inspector_state.pb.zig");
const buffers = @import("inspector_buffers.zig");

const imgui = zignite.imgui;
const engine = zignite.engine;
const InspectorState = inspst.InspectorState;
const SharedBufferReader = buffers.SharedBufferReader;

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
    var reader = try SharedBufferReader.init(file_path);
    defer reader.deinit();

    var e = try engine.Engine.init(.{
        .width = 1024,
        .height = 768,
    });
    defer e.deinit();

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
            std.log.warn("Failed to read data: {}", .{err});
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
