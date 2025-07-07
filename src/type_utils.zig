const std = @import("std");

pub fn anyOpaqueCast(comptime Userdata: type, v: ?*anyopaque) ?*Userdata {
    if (Userdata == void) return null;
    return @ptrCast(@alignCast(v));
}
pub fn unsafeAnyOpaqueCast(comptime Userdata: type, v: ?*anyopaque) *Userdata {
    return @ptrCast(@alignCast(v));
}

pub fn getTypeName(comptime T: type) []const u8 {
    const full_name = @typeName(T);
    if (std.mem.lastIndexOf(u8, full_name, ".")) |last_dot_index| {
        return full_name[last_dot_index + 1 ..];
    } else {
        return full_name;
    }
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
