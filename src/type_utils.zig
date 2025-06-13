const std = @import("std");

pub fn anyOpaqueCast(comptime Userdata: type, v: ?*anyopaque) ?*Userdata {
    if (Userdata == void) return null;
    return @ptrCast(@alignCast(v));
}
pub fn unsafeAnyOpaqueCast(comptime Userdata: type, v: ?*anyopaque) *Userdata {
    return @ptrCast(@alignCast(v));
}

pub fn getTypeNames(comptime T: type) [if (@typeInfo(T) == .@"struct") 1 else @typeInfo(@typeInfo(T).@"union".tag_type.?).@"enum".fields.len][]const u8 {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .@"struct" => {
            const struct_name = @typeName(T);
            const name = if (std.mem.lastIndexOf(u8, struct_name, ".")) |last_dot|
                struct_name[last_dot + 1 ..]
            else
                struct_name;

            return [_][]const u8{name};
        },
        .@"union" => {
            const tag = @typeInfo(T).@"union".tag_type.?;
            const fields = @typeInfo(tag).@"enum".fields;
            var names: [fields.len][]const u8 = undefined;
            inline for (@typeInfo(T).@"union".fields, 0..) |field, i| {
                names[i] = @typeName(field.type);
            }
            return names;
        },
        else => @compileError("Type must be a struct or union"),
    };
}

pub fn getActiveTypeName(message: anytype) []const u8 {
    const T = @TypeOf(message);
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .@"struct" => {
            return @typeName(T);
        },
        .@"union" => {
            const active_tag = std.meta.activeTag(message);
            const TagType = @TypeOf(active_tag);

            inline for (std.meta.fields(TagType)) |field| {
                if (active_tag == @field(TagType, field.name)) {
                    const PayloadType = std.meta.TagPayloadByName(T, field.name);
                    return @typeName(PayloadType);
                }
            }
            return "";
        },
        else => @compileError("Type must be a struct or union"),
    };
}
pub fn hasMethod(comptime T: type, comptime method_name: []const u8) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    inline for (type_info.@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, method_name)) {
            const field = @field(T, decl.name);
            const field_type = @TypeOf(field);
            return @typeInfo(field_type) == .@"fn";
        }
    }
    return false;
}
