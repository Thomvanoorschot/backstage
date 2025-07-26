const std = @import("std");
const backstage = @import("backstage");
const Context = backstage.Context;
const MethodCall = backstage.MethodCall;
const ImportedVariableActor = @import("../imported_variable.zig").ImportedVariableActor;
const FirstExportedVariable = @import("../discared_variable.zig").FirstExportedVariable;
const dv = @import("../discared_variable.zig");

pub const ImportedVariableActorProxy = struct {
    pub const is_proxy = true;
    ctx: *Context,
    allocator: std.mem.Allocator,
    underlying: *ImportedVariableActor,
    
    const Self = @This();

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        const underlying = try ImportedVariableActor.init(ctx, allocator);
        self.* = .{
            .ctx = ctx,
            .allocator = allocator,
            .underlying = underlying,
        };
        return self;
    }

    pub fn deinit(self: *Self) !void {
        try self.underlying.deinit();
        self.allocator.destroy(self);
    }
    inline fn methodWrapper0(self: *Self, params_json: []const u8) !void {
        const params = try std.json.parseFromSlice(struct {
            first: FirstExportedVariable,
            second: dv.SecondExportedVariable,
        }, std.heap.page_allocator, params_json, .{});
        defer params.deinit();
        return self.underlying.handleImportedVariable(params.value.first, params.value.second);
    }

    pub inline fn handleImportedVariable(self: *Self, first: FirstExportedVariable, second: dv.SecondExportedVariable) !void {
        var params_json = std.ArrayList(u8).init(self.allocator);
        defer params_json.deinit();
        try std.json.stringify(.{.first = first, .second = second}, .{}, params_json.writer());
        const params_str = try params_json.toOwnedSlice();
        defer self.allocator.free(params_str);
        const method_call = MethodCall{
            .method_id = 0,
            .params = params_str,
        };
        return self.ctx.dispatchMethodCall(self.ctx.actor_id, method_call);    }

    pub inline fn dispatchMethod(self: *Self, method_call: MethodCall) !void {
        return switch (method_call.method_id) {            0 => methodWrapper0(self, method_call.params),
            else => error.UnknownMethod,
        };
    }
};
