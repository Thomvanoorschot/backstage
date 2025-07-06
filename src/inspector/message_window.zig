const std = @import("std");
const zignite = @import("zignite");
const inspst = @import("inspector_state.pb.zig");

const imgui = zignite.imgui;
const InspectorState = inspst.InspectorState;

pub const MessageWindowState = struct {
    filter_buffer: [256]u8 = std.mem.zeroes([256]u8),

    pub fn init() MessageWindowState {
        return MessageWindowState{};
    }
};

pub fn render(data: InspectorState, state: *MessageWindowState) void {
    imgui.igText("Filter");
    imgui.igSameLine(0, 5);
    _ = imgui.igInputText("##message_filter", &state.filter_buffer, state.filter_buffer.len, 0, null, null);

    imgui.igSeparator();

    imgui.igText("Total actors: %d", data.actors.items.len);

    if (imgui.igBeginTable("MessagesTable", 3, imgui.ImGuiTableFlags_Borders | imgui.ImGuiTableFlags_RowBg, .{ .x = 0, .y = 0 }, 0.0)) {
        imgui.igTableSetupColumn("Timestamp", 0, 0, 0);
        imgui.igTableSetupColumn("Actor", 0, 0, 0);
        imgui.igTableSetupColumn("Message", 0, 0, 0);
        imgui.igTableHeadersRow();

        for (data.actors.items) |actor| {
            imgui.igTableNextRow(0, 0);

            _ = imgui.igTableSetColumnIndex(@intCast(0));
            if (actor.inbox_metrics) |metrics| {
                imgui.igText("%d", metrics.last_message_at);
            } else {
                imgui.igText("N/A");
            }

            _ = imgui.igTableSetColumnIndex(@intCast(1));
            imgui.igText("%s", actor.id.Owned.str.ptr);

            _ = imgui.igTableSetColumnIndex(@intCast(2));
            imgui.igText("Sample message data");
        }

        imgui.igEndTable();
    }
}
