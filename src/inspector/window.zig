const std = @import("std");
const zignite = @import("zignite");
const inspst = @import("inspector_state.pb.zig");
const buffers = @import("buffers.zig");

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
    var group_by_type: bool = false;
    var sort_by_eps: bool = false;
    var filter_buffer: [256]u8 = std.mem.zeroes([256]u8);

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

                _ = imgui.igCheckbox("Group by Type", &group_by_type);

                imgui.igSameLine(0, 20);
                imgui.igText("Sort by");
                imgui.igSameLine(0, 5);
                if (imgui.igBeginCombo("##sort", if (sort_by_eps) "eps" else "ID", 0)) {
                    if (imgui.igSelectable_Bool("ID", !sort_by_eps, 0, .{ .x = 0, .y = 0 })) {
                        sort_by_eps = false;
                    }
                    if (imgui.igSelectable_Bool("eps", sort_by_eps, 0, .{ .x = 0, .y = 0 })) {
                        sort_by_eps = true;
                    }
                    imgui.igEndCombo();
                }

                imgui.igText("Filter");
                imgui.igSameLine(0, 5);
                _ = imgui.igInputText("##filter", &filter_buffer, filter_buffer.len, 0, null, null);

                imgui.igSeparator();

                if (group_by_type) {
                    renderGroupedActors(data.actors.items, sort_by_eps);
                } else {
                    renderFlatActors(data.actors.items, sort_by_eps);
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

fn setupActorTable() void {
    imgui.igTableSetupColumn("ID", 0, 0, 0);
    imgui.igTableSetupColumn("Type", 0, 0, 0);
    imgui.igTableSetupColumn("eps", 0, 0, 0);
    imgui.igTableSetupColumn("Inbox Length", 0, 0, 0);
    imgui.igTableHeadersRow();
}

fn sortActors(actors: []inspst.ActorSnapshot, sort_by_eps: bool) void {
    if (sort_by_eps) {
        std.mem.sort(inspst.ActorSnapshot, actors, {}, compareByEps);
    } else {
        std.mem.sort(inspst.ActorSnapshot, actors, {}, compareById);
    }
}

fn getActorEps(actor: inspst.ActorSnapshot) f64 {
    return if (actor.inbox_metrics) |metrics|
        if (metrics.throughput_metrics) |throughput|
            throughput.rolling_average_eps
        else
            0.0
    else
        0.0;
}

fn getActorInboxLength(actor: inspst.ActorSnapshot) u64 {
    return if (actor.inbox_metrics != null and actor.inbox_metrics.?.envelope_count > 0)
        @intCast(actor.inbox_metrics.?.envelope_count)
    else
        0;
}

fn renderActorTableRow(actor: inspst.ActorSnapshot) void {
    imgui.igTableNextRow(0, 0);

    _ = imgui.igTableSetColumnIndex(@intCast(0));
    imgui.igText("%s", actor.id.Owned.str.ptr);

    _ = imgui.igTableSetColumnIndex(@intCast(1));
    imgui.igText("%s", actor.actor_type_name.Owned.str.ptr);

    _ = imgui.igTableSetColumnIndex(@intCast(2));
    const eps = getActorEps(actor);
    if (eps == 0.0) {
        imgui.igText("0,0");
    } else {
        imgui.igText("%.1f", eps);
    }

    _ = imgui.igTableSetColumnIndex(@intCast(3));
    const inbox_length = getActorInboxLength(actor);
    imgui.igText("%d", inbox_length);
}

fn renderActorTable(table_id: []const u8, actors: []inspst.ActorSnapshot, sort_by_eps: bool) void {
    if (imgui.igBeginTable(table_id.ptr, 4, imgui.ImGuiTableFlags_Borders | imgui.ImGuiTableFlags_RowBg, .{ .x = 0, .y = 0 }, 0.0)) {
        setupActorTable();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        const sorted_actors = temp_allocator.alloc(inspst.ActorSnapshot, actors.len) catch return;
        @memcpy(sorted_actors, actors);
        sortActors(sorted_actors, sort_by_eps);

        for (sorted_actors) |actor| {
            renderActorTableRow(actor);
        }

        imgui.igEndTable();
    }
}

fn getFlatActorDisplayName(actor: inspst.ActorSnapshot, _: usize) []const u8 {
    return actor.actor_type_name.Owned.str;
}

fn renderFlatActors(actors: []const inspst.ActorSnapshot, sort_by_eps: bool) void {
    imgui.igText("Actors");
    renderActorTable("ActorsTable", @constCast(actors), sort_by_eps);
}

fn renderGroupedActors(actors: []const inspst.ActorSnapshot, sort_by_eps: bool) void {
    imgui.igText("Actor Groups");

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_allocator = arena.allocator();

    var groups = std.StringHashMap(std.ArrayList(inspst.ActorSnapshot)).init(temp_allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        groups.deinit();
    }

    for (actors) |actor| {
        var group = groups.getPtr(actor.actor_type_name.Owned.str);
        if (group == null) {
            groups.put(actor.actor_type_name.Owned.str, std.ArrayList(inspst.ActorSnapshot).init(temp_allocator)) catch continue;
            group = groups.getPtr(actor.actor_type_name.Owned.str);
        }
        group.?.append(actor) catch continue;
    }

    var group_it = groups.iterator();
    while (group_it.next()) |entry| {
        const group_name = entry.key_ptr.*;
        const group_actors = entry.value_ptr.*;

        if (imgui.igCollapsingHeader_TreeNodeFlags(group_name.ptr, imgui.ImGuiTreeNodeFlags_DefaultOpen)) {
            renderActorTableWithGroupName(group_name, group_actors.items, sort_by_eps);
        }
    }
}

fn renderActorTableWithGroupName(table_id: []const u8, actors: []inspst.ActorSnapshot, sort_by_eps: bool) void {
    if (imgui.igBeginTable(table_id.ptr, 4, imgui.ImGuiTableFlags_Borders | imgui.ImGuiTableFlags_RowBg, .{ .x = 0, .y = 0 }, 0.0)) {
        setupActorTable();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        const sorted_actors = temp_allocator.alloc(inspst.ActorSnapshot, actors.len) catch return;
        @memcpy(sorted_actors, actors);
        sortActors(sorted_actors, sort_by_eps);

        for (sorted_actors) |actor| {
            renderActorTableRow(actor);
        }

        imgui.igEndTable();
    }
}

fn compareByEps(_: void, a: inspst.ActorSnapshot, b: inspst.ActorSnapshot) bool {
    const eps_a = if (a.inbox_metrics) |metrics|
        if (metrics.throughput_metrics) |throughput|
            throughput.rolling_average_eps
        else
            0.0
    else
        0.0;

    const eps_b = if (b.inbox_metrics) |metrics|
        if (metrics.throughput_metrics) |throughput|
            throughput.rolling_average_eps
        else
            0.0
    else
        0.0;

    return eps_a > eps_b;
}

fn compareById(_: void, a: inspst.ActorSnapshot, b: inspst.ActorSnapshot) bool {
    return std.mem.lessThan(u8, a.id.Owned.str, b.id.Owned.str);
}
