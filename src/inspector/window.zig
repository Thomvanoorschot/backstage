const std = @import("std");
const zignite = @import("zignite");
const inspst = @import("inspector_state.pb.zig");
const buffers = @import("buffers.zig");
const actor_window = @import("actor_window.zig");
const message_window = @import("message_window.zig");

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
        .width = 1280,
        .height = 960,
    });
    defer e.deinit();

    var last_state: ?InspectorState = null;
    var actor_state = actor_window.ActorWindowState.init();
    var message_state = message_window.MessageWindowState.init();

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

        if (imgui.igBegin("Actor Inspector", null, 0)) {
            if (last_state) |data| {
                if (data.inbox_throughput_metrics) |throughput_metrics| {
                    imgui.igText("Messages per second: %.2f", throughput_metrics.rolling_average_eps);
                } else {
                    imgui.igText("Messages per second: 0.0");
                }

                imgui.igSeparator();

                if (imgui.igBeginTabBar("InspectorTabs", 0)) {
                    if (imgui.igBeginTabItem("Actors", null, 0)) {
                        actor_window.render(data, &actor_state);
                        imgui.igEndTabItem();
                    }

                    if (imgui.igBeginTabItem("Messages", null, 0)) {
                        message_window.render(data, &message_state);
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