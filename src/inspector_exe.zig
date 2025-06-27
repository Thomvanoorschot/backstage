const std = @import("std");
const zignite = @import("zignite");

const imgui = zignite.imgui;
const engine = zignite.engine;

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

    const file_size = 1024;
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

    while (e.startRender()) {
        defer e.endRender();
        const data_ptr: [*:0]const u8 = @ptrCast(mmap_ptr.ptr);
        const data_str = std.mem.span(data_ptr);
        if (imgui.igBegin("Backstage Inspector", null, 0)) {
            imgui.igText(data_str.ptr, .{});
        }
        imgui.igEnd();
    }
}
